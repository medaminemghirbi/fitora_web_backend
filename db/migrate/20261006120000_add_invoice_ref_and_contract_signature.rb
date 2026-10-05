# Two things a gym hands a member with every abonnement:
#
#   contracts.invoice_ref — the invoice reference printed on the receipt and
#     on the signed contract: FAC-2026-0001, counted per salle and per year
#     (contract_invoice_sequences), so each salle's numbering is its own and
#     has no gaps. Existing contracts are numbered in the order they were
#     sold.
#
#   companies.signatory_name / contract_terms (+ an attached `signature`
#     image) — who signs the gym's contracts and the clauses they print,
#     set once in Settings and applied to every contract PDF.
class AddInvoiceRefAndContractSignature < ActiveRecord::Migration[8.1]
  def up
    create_table :contract_invoice_sequences, id: :uuid do |t|
      t.references :company, type: :uuid, null: false, foreign_key: true, index: false
      t.integer :year, null: false
      t.integer :last_value, null: false, default: 0
      t.timestamps
    end
    add_index :contract_invoice_sequences, [ :company_id, :year ], unique: true

    add_column :contracts, :invoice_ref, :string

    execute <<~SQL.squish
      UPDATE contracts c SET invoice_ref = numbered.ref
      FROM (
        SELECT id, 'FAC-' || EXTRACT(YEAR FROM created_at)::int || '-' ||
               LPAD(ROW_NUMBER() OVER (PARTITION BY company_id, EXTRACT(YEAR FROM created_at)
                                       ORDER BY created_at, id)::text, 4, '0') AS ref
        FROM contracts
      ) numbered
      WHERE numbered.id = c.id
    SQL

    execute <<~SQL.squish
      INSERT INTO contract_invoice_sequences (id, company_id, year, last_value, created_at, updated_at)
      SELECT gen_random_uuid(), company_id, EXTRACT(YEAR FROM created_at)::int, COUNT(*), now(), now()
      FROM contracts
      GROUP BY company_id, EXTRACT(YEAR FROM created_at)
    SQL

    change_column_null :contracts, :invoice_ref, false
    add_index :contracts, [ :company_id, :invoice_ref ], unique: true

    add_column :companies, :signatory_name, :string
    add_column :companies, :contract_terms, :text
  end

  def down
    remove_column :companies, :contract_terms
    remove_column :companies, :signatory_name
    remove_index :contracts, [ :company_id, :invoice_ref ]
    remove_column :contracts, :invoice_ref
    drop_table :contract_invoice_sequences
  end
end
