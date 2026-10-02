require "prawn"
require "prawn/table"

# PDF's built-in fonts (WinAnsi/CP1252) cover accented French fine; every
# string here is already checked against that encoding, so the warning is
# noise, not a real limitation.
Prawn::Fonts::AFM.hide_m17n_warning = true

module Receipts
  # The "reçu / facture" PDF for one abonnement — laid out like a standard
  # invoice: letterhead, a Destinataire / Facture block, a line-item table,
  # a right-aligned totals block and the general terms. One page, downloaded
  # on demand (ContractsController#receipt), never stored.
  class ContractPdf
    INK = "1A1330".freeze
    GREY = "6B6386".freeze
    LINE = "D9D2E6".freeze
    HAIR = "999999".freeze

    UNIT_BY_PERIOD = {
      "monthly" => "mois", "quarterly" => "trimestre",
      "semi_annual" => "semestre", "yearly" => "année"
    }.freeze

    def self.call(contract:)
      new(contract: contract).call
    end

    def initialize(contract:)
      @contract = contract
      @company = contract.company
      @client = contract.client
      @plan = contract.contract_type
    end

    def call
      Prawn::Document.new(page_size: "A4", margin: 48) do |pdf|
        letterhead(pdf)
        parties(pdf)
        pdf.move_down 28
        items_table(pdf)
        pdf.move_down 10
        totals(pdf)
        pdf.move_down 34
        conditions(pdf)
        page_footer(pdf)
      end.render
    end

    private

    attr_reader :contract, :company, :client, :plan

    # ---- letterhead ---------------------------------------------------------
    def letterhead(pdf)
      top = pdf.cursor
      half = pdf.bounds.width / 2

      pdf.fill_color INK
      pdf.text_box company.name, at: [ 0, top ], width: half, size: 22, style: :bold
      pdf.fill_color "000000"

      right = []
      addr = [ company.address, company.city ].compact_blank.join(" - ")
      right << addr if addr.present?
      right << "E-mail: #{company.email}" if company.email.present?
      right << "Téléphone: #{company.phone}" if company.phone.present?
      right << company.country if company.country.present? && addr.blank?

      pdf.fill_color GREY
      pdf.text_box right.join("\n"), at: [ half, top ], width: half, align: :right, size: 9, leading: 3
      pdf.fill_color "000000"

      pdf.move_cursor_to top - [ 34, right.size * 13 + 4 ].max
      pdf.move_down 18
      pdf.stroke_color HAIR
      pdf.stroke_horizontal_rule
      pdf.stroke_color "000000"
      pdf.move_down 26
    end

    # ---- Destinataire / Facture -------------------------------------------
    def parties(pdf)
      top = pdf.cursor

      pdf.fill_color GREY
      pdf.text_box "Destinataire:", at: [ 0, top ], width: 90, size: 10
      pdf.fill_color INK
      dest = [ client.full_name, client.membership_for(company)&.address, client.phone, client.email ].compact_blank
      pdf.text_box dest.join("\n"), at: [ 95, top ], width: 220, size: 10, leading: 3
      pdf.fill_color "000000"

      meta = [
        [ "Facture:", invoice_number, true ],
        [ "Date de facture:", fmt_date(invoice_date), false ],
        [ "Date d'échéance:", fmt_date(contract.expires_at), false ]
      ]
      y = top
      meta.each do |label, value, strong|
        size = strong ? 12 : 10
        pdf.fill_color strong ? INK : GREY
        pdf.text_box label, at: [ pdf.bounds.width - 300, y ], width: 210, align: :right, size: size, style: (strong ? :bold : :normal)
        pdf.fill_color INK
        pdf.text_box value, at: [ pdf.bounds.width - 80, y ], width: 80, align: :right, size: size, style: (strong ? :bold : :normal)
        y -= strong ? 24 : 20
      end
      pdf.fill_color "000000"

      pdf.move_cursor_to [ top - dest.size * 13 - 4, y ].min
    end

    # ---- line items ------------------------------------------------------
    def items_table(pdf)
      head = %w[Description Quantité Unité Prix Montant]
      billed = contract.current_period&.base_price.to_f
      rows = [ [ item_description, "1", unit_label, num(billed), num(billed) ] ]
      if contract.discount.to_f.positive?
        rows << [ "Remise", "", "", "", "-#{num(contract.discount)}" ]
      end

      pdf.table([ head ] + rows, width: pdf.bounds.width, column_widths: { 0 => 230 }) do |t|
        t.cells.borders = []
        t.cells.padding = [ 10, 6 ]
        t.cells.size = 10
        t.column(0).inline_format = true

        t.row(0).borders = [ :bottom ]
        t.row(0).border_color = HAIR
        t.row(0).font_style = :bold
        t.row(0).text_color = GREY

        t.rows(1..-1).borders = [ :bottom ]
        t.rows(1..-1).border_color = LINE

        t.column(1).align = :center
        t.columns(3..4).align = :right
      end
    end

    # ---- totals (right-aligned block) ----------------------------------
    def totals(pdf)
      subtotal = contract.final_price.to_f
      paid = contract.payments.paid.sum(:amount).to_f
      due = [ subtotal - paid, 0 ].max
      cur = plan.currency

      block_w = pdf.bounds.width * 0.5
      pdf.bounding_box([ pdf.bounds.width - block_w, pdf.cursor ], width: block_w) do
        line(pdf, "Sous-total HT", num(subtotal))
        line(pdf, "Montant Total #{cur}", num(subtotal), bold: true)

        pdf.move_down 6
        pdf.stroke_color LINE
        pdf.stroke_horizontal_rule
        pdf.stroke_color "000000"
        pdf.move_down 8

        line(pdf, "Montant payé", num(paid))
        line(pdf, "Montant à payer (#{cur})", num(due), bold: true, size: 13)
      end
    end

    def line(pdf, label, value, bold: false, size: 10)
      y = pdf.cursor
      val_w = 90
      pdf.fill_color bold ? INK : GREY
      pdf.text_box label, at: [ 0, y ], width: pdf.bounds.width - val_w - 8, size: size, style: (bold ? :bold : :normal)
      pdf.fill_color INK
      pdf.text_box value, at: [ pdf.bounds.width - val_w, y ], width: val_w, align: :right, size: size, style: (bold ? :bold : :normal)
      pdf.fill_color "000000"
      pdf.move_down size + 8
    end

    # ---- terms ---------------------------------------------------------
    def conditions(pdf)
      pdf.fill_color INK
      pdf.text "Conditions générales", size: 11, style: :bold
      pdf.fill_color GREY
      pdf.move_down 4
      pdf.text conditions_text, size: 9, leading: 2
      pdf.fill_color "000000"
    end

    def conditions_text
      status = contract.paid? ? "Montant réglé, aucun solde restant dû." : "Montant restant dû à régler avant la date d'échéance."
      "#{status} Reçu établi pour l'abonnement « #{plan.name} » sur la période indiquée. Montant net de taxe."
    end

    # ---- footer, anchored to the bottom of the page ------------------
    def page_footer(pdf)
      pdf.canvas do
        x = pdf.bounds.left + 48
        w = pdf.bounds.width - 96
        pdf.stroke_color LINE
        pdf.horizontal_line x, x + w, at: 74
        pdf.stroke
        pdf.stroke_color "000000"

        pdf.fill_color GREY
        pdf.text_box "Édité avec le logiciel Gymly · Tous droits réservés",
                     at: [ x, 66 ], width: w, align: :center, size: 8
        pdf.text_box "Reçu ##{invoice_number} · #{fmt_date(Time.current)}",
                     at: [ x, 52 ], width: w, align: :center, size: 7
        pdf.fill_color "000000"
      end
    end

    # ---- helpers -----------------------------------------------------
    def item_description
      title = "#{plan.name} — #{contract.activity_label}"
      return title if plan.description.blank?

      "#{title}\n<font size='8'><color rgb='#{GREY}'>#{plan.description}</color></font>"
    end

    def unit_label
      UNIT_BY_PERIOD.fetch(plan.billing_period, plan.billing_period)
    end

    def invoice_number
      contract.id.split("-").first.upcase
    end

    def invoice_date
      contract.starts_at || contract.created_at
    end

    def fmt_date(value)
      value&.to_date&.strftime("%d/%m/%Y") || "—"
    end

    # French number formatting — "1.004,00".
    def num(value)
      whole, frac = format("%.2f", value.to_f).split(".")
      whole = whole.reverse.gsub(/(\d{3})(?=\d)/, '\1.').reverse
      "#{whole},#{frac}"
    end
  end
end
