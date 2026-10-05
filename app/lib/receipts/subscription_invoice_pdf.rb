require "prawn"
require "prawn/table"

Prawn::Fonts::AFM.hide_m17n_warning = true

module Receipts
  # Fitora's own invoice to a gym, for one period of access.
  #
  # The counterpart of ContractPdf, which invoices a gym's member: same
  # shape, opposite direction — here Fitora is the sender and the gym the
  # recipient. Rendered on demand, never stored: the Invoice row holds
  # everything, amount included, frozen at issue.
  #
  # No VAT line. Fitora's tax position is not recorded anywhere in the app,
  # and inventing a rate on a document a gym may file is worse than leaving
  # it off — add it here once the real matricule fiscal exists.
  class SubscriptionInvoicePdf
    INK = "1A1330".freeze
    GREY = "6B6386".freeze
    LINE = "D9D2E6".freeze
    HAIR = "999999".freeze

    LABEL_BY_PERIOD = { "monthly" => "mois", "yearly" => "année" }.freeze
    PLAN_LABELS = { "starter" => "Starter", "pro" => "Pro" }.freeze

    def self.call(invoice:)
      new(invoice: invoice).call
    end

    def initialize(invoice:)
      @invoice = invoice
      # Billed to the account, headed by its first salle.
      @company = invoice.billing_company
      @admin = invoice.admin
    end

    def call
      Prawn::Document.new(page_size: "A4", margin: 48) do |pdf|
        letterhead(pdf)
        parties(pdf)
        pdf.move_down 28
        items_table(pdf)
        pdf.move_down 10
        total(pdf)
        pdf.move_down 34
        settled(pdf)
        page_footer(pdf)
      end.render
    end

    private

    attr_reader :invoice, :company, :admin

    def letterhead(pdf)
      top = pdf.cursor
      half = pdf.bounds.width / 2

      pdf.fill_color INK
      pdf.text_box "FITORA", at: [ 0, top ], width: half, size: 22, style: :bold
      pdf.fill_color GREY
      pdf.text_box "Logiciel de gestion pour salles de sport", at: [ 0, top - 26 ], width: half, size: 9

      pdf.text_box "Facture #{invoice.number}\nÉmise le #{fr_date(invoice.issued_at.to_date)}",
                   at: [ half, top ], width: half, align: :right, size: 10, leading: 3
      pdf.fill_color "000000"

      pdf.move_cursor_to top - 46
      pdf.stroke_color HAIR
      pdf.stroke_horizontal_rule
      pdf.stroke_color "000000"
      pdf.move_down 26
    end

    def parties(pdf)
      top = pdf.cursor

      pdf.fill_color GREY
      pdf.text_box "Destinataire:", at: [ 0, top ], width: 90, size: 10
      pdf.fill_color INK
      dest = [ company&.name, admin&.full_name, company&.address, company&.city, company&.email ].compact_blank
      pdf.text_box dest.join("\n"), at: [ 95, top ], width: 240, size: 10, leading: 3
      pdf.fill_color "000000"

      pdf.move_cursor_to top - (dest.size * 13 + 6)
    end

    def items_table(pdf)
      rows = [
        [ "Désignation", "Période", "Montant" ],
        [ designation, period_label, money(invoice.amount) ]
      ]

      pdf.table(rows, width: pdf.bounds.width, cell_style: { size: 10, borders: [ :bottom ], border_color: LINE, padding: [ 8, 6 ] }) do
        row(0).font_style = :bold
        row(0).text_color = GREY
        row(0).size = 9
        columns(2).align = :right
        columns(1).align = :center
      end
    end

    def total(pdf)
      pdf.bounding_box([ pdf.bounds.width - 220, pdf.cursor ], width: 220) do
        pdf.stroke_color INK
        pdf.stroke_horizontal_rule
        pdf.stroke_color "000000"
        pdf.move_down 8
        pdf.fill_color INK
        pdf.text "Total   #{money(invoice.amount)}", size: 14, style: :bold, align: :right
        pdf.fill_color "000000"
      end
    end

    def settled(pdf)
      pdf.fill_color GREY
      lines = [ "Facture réglée — paiement confirmé le #{fr_date(invoice.issued_at.to_date)}." ]
      lines << "Confirmée par #{invoice.issued_by.full_name}." if invoice.issued_by
      lines << invoice.notes if invoice.notes.present?
      pdf.text lines.join(" "), size: 9, leading: 3
      pdf.fill_color "000000"
    end

    def page_footer(pdf)
      pdf.repeat(:all) do
        pdf.fill_color GREY
        pdf.draw_text "Fitora · #{invoice.number}", at: [ 0, 12 ], size: 8
        pdf.fill_color "000000"
      end
    end

    def designation
      return "Fitora — période d'essai" if invoice.trial?

      "Fitora #{PLAN_LABELS.fetch(invoice.plan, invoice.plan)} — #{LABEL_BY_PERIOD.fetch(invoice.billing_period, invoice.billing_period)}"
    end

    # PDF's built-in fonts are WinAnsi: an arrow or an em-dash here raises
    # rather than degrading, so the range is spelled out in words.
    def period_label
      "du #{fr_date(invoice.period_start)}\nau #{fr_date(invoice.period_end)}"
    end

    def money(amount)
      "#{format('%.2f', amount).tr('.', ',')} #{invoice.currency}"
    end

    MONTHS = %w[janvier février mars avril mai juin juillet août septembre octobre novembre décembre].freeze

    def fr_date(date)
      "#{date.day} #{MONTHS[date.month - 1]} #{date.year}"
    end
  end
end
