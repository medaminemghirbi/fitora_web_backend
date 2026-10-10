require "prawn"
require "prawn/table"

Prawn::Fonts::AFM.hide_m17n_warning = true

module Receipts
  # The abonnement contract itself — what the member signs, as opposed to
  # the invoice (Receipts::ContractPdf). Letterhead with the gym's logo, the
  # two parties, numbered articles (object, term, sessions, price, terms)
  # and the signature block: the gym's default signature already in place
  # (Settings → signature + signatory_name), the member's left to sign.
  #
  # The general terms are the gym's own (companies.contract_terms) when it
  # has written some, else DEFAULT_TERMS. Built on demand, never stored.
  class ContractAgreementPdf
    INK = "1A1330".freeze
    GREY = "6B6386".freeze
    LINE = "D9D2E6".freeze
    SOFT = "F4F1FA".freeze

    DEFAULT_TERMS = [
      "Le membre s'engage à respecter le règlement intérieur du club et les consignes de l'équipe encadrante.",
      "L'abonnement est strictement personnel : il ne peut être ni cédé, ni prêté.",
      "Le membre déclare être apte à la pratique sportive et avoir signalé au club toute contre-indication médicale.",
      "Une suspension (blessure, grossesse, absence prolongée) peut être accordée sur justificatif ; " \
      "sa durée est alors reportée sur la date de fin du contrat.",
      "Les séances non utilisées à la date de fin du contrat ne sont ni reportées ni remboursées, sauf accord écrit du club.",
      "Toute somme due doit être réglée au plus tard à la date de début du contrat, sauf accord du club.",
      "Le club décline toute responsabilité en cas de perte ou de vol d'effets personnels dans ses locaux."
    ].freeze

    def self.call(contract:)
      new(contract: contract).call
    end

    def initialize(contract:)
      @contract = contract
      @company = contract.company
      @client = contract.client
      @plan = contract.contract_type
      @membership = contract.client.membership_for(contract.company)
    end

    def call
      Prawn::Document.new(page_size: "A4", margin: [ 44, 48, 74, 48 ], info: { Title: "Contrat #{contract.invoice_ref}" }) do |pdf|
        letterhead(pdf)
        parties(pdf)
        articles(pdf)
        signatures(pdf)
        footer(pdf)
      end.render
    end

    private

    attr_reader :contract, :company, :client, :plan, :membership

    # ---- letterhead -------------------------------------------------------
    def letterhead(pdf)
      top = pdf.cursor
      half = pdf.bounds.width / 2

      name_top = top
      if (logo = PrintableImage.io(company.brand_logo))
        pdf.image logo, at: [ 0, top ], fit: [ 150, 46 ]
        name_top = top - 52
      end
      pdf.fill_color INK
      pdf.text_box company.name, at: [ 0, name_top ], width: half, size: logo ? 13 : 20, style: :bold

      pdf.text_box "CONTRAT D'ABONNEMENT", at: [ half, top ], width: half, align: :right, size: 16, style: :bold
      pdf.fill_color GREY
      pdf.text_box "Réf. #{contract.invoice_ref}\nÉtabli le #{fmt_date(contract.created_at)}",
                   at: [ half, top - 24 ], width: half, align: :right, size: 9, leading: 3
      pdf.fill_color "000000"

      pdf.move_cursor_to top - (logo ? 76 : 50)
      rule(pdf)
      pdf.move_down 16
    end

    # ---- the two parties ---------------------------------------------------
    def parties(pdf)
      pdf.fill_color INK
      pdf.text "Entre les soussignés", size: 11, style: :bold
      pdf.fill_color "000000"
      pdf.move_down 8

      gap = 14
      width = (pdf.bounds.width - gap) / 2
      club = [
        company.name,
        [ company.address, company.city ].compact_blank.join(", "),
        company.phone.presence && "Tél. : #{company.phone}",
        company.email.presence && "E-mail : #{company.email}",
        company.signatory_name.presence && "Représenté par : #{company.signatory_name}"
      ].compact_blank
      member = [
        client.full_name,
        membership&.date_of_birth && "Né(e) le #{fmt_date(membership.date_of_birth)}",
        membership&.address,
        client.phone.presence && "Tél. : #{client.phone}",
        client.email.presence && "E-mail : #{client.email}"
      ].compact_blank

      top = pdf.cursor
      height = ([ club.size, member.size ].max * 13) + 34
      party_box(pdf, "LE CLUB", club, at: [ 0, top ], width: width, height: height)
      party_box(pdf, "LE MEMBRE", member, at: [ width + gap, top ], width: width, height: height)
      pdf.move_cursor_to top - height - 18
    end

    def party_box(pdf, title, lines, at:, width:, height:)
      pdf.bounding_box(at, width: width, height: height) do
        pdf.fill_color SOFT
        pdf.fill_rounded_rectangle [ 0, height ], width, height, 6
        pdf.fill_color GREY
        pdf.text_box title, at: [ 12, height - 12 ], width: width - 24, size: 8, style: :bold, character_spacing: 1
        pdf.fill_color INK
        pdf.text_box lines.first.to_s, at: [ 12, height - 26 ], width: width - 24, size: 11, style: :bold
        pdf.text_box lines.drop(1).join("\n"), at: [ 12, height - 42 ], width: width - 24, size: 9, leading: 3
        pdf.fill_color "000000"
      end
    end

    # ---- the articles -------------------------------------------------------
    def articles(pdf)
      article(pdf, 1, "Objet",
              "Le présent contrat donne accès à la formule « #{plan.name} » pour : #{contract.activity_label}." +
              (plan.description.present? ? " #{plan.description}" : ""))

      term = "Le contrat prend effet le #{fmt_date(contract.starts_at)} et prend fin le #{fmt_date(contract.expires_at)}"
      term += " (#{duration_days} jours)" if duration_days
      term += "."
      term += " Il renouvelle le contrat Réf. #{contract.renewed_from.invoice_ref}." if contract.renewed_from
      article(pdf, 2, "Durée", term)

      article(pdf, 3, "Séances", sessions_text)

      article(pdf, 4, "Prix et règlement", nil)
      price_table(pdf)
      pdf.move_down 6
      paragraph(pdf, payment_text)
      pdf.move_down 10

      article(pdf, 5, "Conditions générales", nil)
      terms.each_with_index do |clause, index|
        paragraph(pdf, "#{index + 1}. #{clause}")
        pdf.move_down 3
      end
      pdf.move_down 10
    end

    def article(pdf, number, title, body)
      keep_room(pdf, 60)
      pdf.fill_color INK
      pdf.text "Article #{number} — #{title}", size: 10.5, style: :bold
      pdf.fill_color "000000"
      pdf.move_down 4
      return if body.nil?

      paragraph(pdf, body)
      pdf.move_down 10
    end

    def paragraph(pdf, text)
      pdf.fill_color GREY
      pdf.text text, size: 9.5, leading: 2.5, align: :justify
      pdf.fill_color "000000"
    end

    def price_table(pdf)
      cur = plan.currency
      rows = [ [ "Prix de la formule", "#{num(contract.base_price)} #{cur}" ] ]
      rows << [ "Remise", "- #{num(contract.discount)} #{cur}" ] if contract.discount.to_f.positive?
      rows << [ "Total", "#{num(contract.final_price)} #{cur}" ]

      pdf.table(rows, width: pdf.bounds.width * 0.6) do |t|
        t.cells.borders = [ :bottom ]
        t.cells.border_color = LINE
        t.cells.padding = [ 5, 4 ]
        t.cells.size = 9.5
        t.cells.text_color = INK
        t.column(1).align = :right
        t.row(-1).font_style = :bold
      end
    end

    def terms
      custom = company.contract_terms.to_s.split(/\r?\n/).map(&:strip).compact_blank
      custom.any? ? custom.map { |line| line.sub(/\A\d+[.)]\s*/, "") } : DEFAULT_TERMS
    end

    # ---- signatures ---------------------------------------------------------
    def signatures(pdf)
      keep_room(pdf, 128)
      city = company.city.presence
      paragraph(pdf, "Fait en deux exemplaires#{city ? " à #{city}" : ''}, le #{fmt_date(Time.current)}.")
      pdf.move_down 10

      gap = 24
      width = (pdf.bounds.width - gap) / 2
      top = pdf.cursor

      pdf.bounding_box([ 0, top ], width: width, height: 100) do
        signature_heading(pdf, "Pour le club")
        if (signature = PrintableImage.io(company.signature))
          pdf.image signature, at: [ 0, 86 ], fit: [ width * 0.7, 52 ]
        end
        signature_line(pdf, company.signatory_name.presence || company.name, width)
      end

      pdf.bounding_box([ width + gap, top ], width: width, height: 100) do
        signature_heading(pdf, "Le membre")
        pdf.fill_color GREY
        pdf.text_box "Précédé de la mention « Lu et approuvé »", at: [ 0, 84 ], width: width, size: 8, style: :italic
        pdf.fill_color "000000"
        signature_line(pdf, client.full_name, width)
      end
      pdf.move_cursor_to top - 104
    end

    def signature_heading(pdf, text)
      pdf.fill_color INK
      pdf.text_box text, at: [ 0, 100 ], width: pdf.bounds.width, size: 10, style: :bold
      pdf.fill_color "000000"
    end

    def signature_line(pdf, name, width)
      pdf.stroke_color LINE
      pdf.stroke_horizontal_line 0, width, at: 22
      pdf.stroke_color "000000"
      pdf.fill_color GREY
      pdf.text_box name, at: [ 0, 16 ], width: width, size: 9
      pdf.fill_color "000000"
    end

    # ---- footer, on every page ------------------------------------------------
    def footer(pdf)
      pdf.repeat(:all) do
        pdf.canvas do
          x = 48
          w = pdf.bounds.width - 96
          pdf.stroke_color LINE
          pdf.stroke_horizontal_line x, x + w, at: 62
          pdf.stroke_color "000000"
          pdf.fill_color GREY
          pdf.text_box "Contrat #{contract.invoice_ref} · #{company.name} · Édité avec le logiciel Fitora",
                       at: [ x, 54 ], width: w, align: :center, size: 7.5
          pdf.fill_color "000000"
        end
      end
      pdf.number_pages "Page <page>/<total>", at: [ pdf.bounds.right - 80, -38 ], width: 80, align: :right, size: 7.5, color: GREY
    end

    # ---- helpers ----------------------------------------------------------------
    def sessions_text
      if plan.unlimited_bookings? || contract.remaining_bookings.nil? && plan.booking_limit.nil?
        "Accès illimité aux séances couvertes par la formule pendant toute la durée du contrat."
      else
        count = plan.booking_limit || plan.session_count
        "#{count} séance(s) incluse(s), à utiliser avant la date de fin du contrat."
      end
    end

    def payment_text
      if contract.paid?
        paid_at = contract.payments.paid.maximum(:paid_at)
        "Montant réglé#{paid_at ? " le #{fmt_date(paid_at)}" : ''} — facture Réf. #{contract.invoice_ref}."
      else
        "Montant à régler au plus tard le #{fmt_date(contract.starts_at)} — facture Réf. #{contract.invoice_ref}."
      end
    end

    def duration_days
      return nil if contract.starts_at.blank? || contract.expires_at.blank?

      (contract.expires_at.to_date - contract.starts_at.to_date).to_i
    end

    def keep_room(pdf, height)
      pdf.start_new_page if pdf.cursor < height
    end

    def rule(pdf)
      pdf.stroke_color LINE
      pdf.stroke_horizontal_rule
      pdf.stroke_color "000000"
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
