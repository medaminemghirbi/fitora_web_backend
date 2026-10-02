require "caxlsx"

module Reports
  # Builds the "export" workbook an admin downloads from
  # admin/reports — a summary sheet (revenue for the chosen period, broken
  # down by payment method, plus client/contract/team counts) and a
  # clients sheet color-coded by active/inactive status. Colors are real
  # Excel cell fills (Axlsx), not just text, since plain CSV can't carry them.
  class CompanyWorkbook
    BRAND = "4F46E5".freeze
    ACTIVE_FILL = "C6EFCE".freeze
    ACTIVE_TEXT = "006100".freeze
    INACTIVE_FILL = "FFC7CE".freeze
    INACTIVE_TEXT = "9C0006".freeze

    def self.call(company:, period:)
      new(company: company, period: period).call
    end

    def initialize(company:, period:)
      @company = company
      @period = period
      @package = Axlsx::Package.new
    end

    def call
      build_summary_sheet
      build_clients_sheet
      package
    end

    private

    attr_reader :company, :period, :package

    def styles
      @styles ||= package.workbook.styles
    end

    def header_style
      @header_style ||= styles.add_style(bg_color: BRAND, fg_color: "FFFFFF", b: true, alignment: { horizontal: :left })
    end

    def title_style
      @title_style ||= styles.add_style(b: true, sz: 14)
    end

    def label_style
      @label_style ||= styles.add_style(b: true)
    end

    def active_style
      @active_style ||= styles.add_style(bg_color: ACTIVE_FILL, fg_color: ACTIVE_TEXT)
    end

    def inactive_style
      @inactive_style ||= styles.add_style(bg_color: INACTIVE_FILL, fg_color: INACTIVE_TEXT)
    end

    def build_summary_sheet
      package.workbook.add_worksheet(name: "Résumé") do |sheet|
        sheet.add_row [ "Rapport Gymly — #{company.name}" ], style: title_style
        sheet.add_row [ "Période : #{period.label}" ]
        sheet.add_row [ "Généré le : #{Time.current.strftime('%d/%m/%Y %H:%M')}" ]
        sheet.add_row []
        sheet.add_row [ "Indicateur", "Valeur" ], style: [ header_style, header_style ]

        summary_rows.each { |label, value| sheet.add_row [ label, value ], style: [ label_style, nil ] }

        sheet.column_widths 34, 20
      end
    end

    def summary_rows
      [
        [ "Revenu total", revenue_total ],
        [ "  dont espèces", revenue_by_method["cash"] || 0 ],
        [ "  dont carte", revenue_by_method["card"] || 0 ],
        [ "  dont virement", revenue_by_method["bank_transfer"] || 0 ],
        [ "  dont autre", revenue_by_method["other"] || 0 ],
        [ "Clients actifs", company.memberships.active.count ],
        [ "Clients inactifs", company.memberships.where(active: false).count ],
        [ "Abonnements actifs", company.contract_periods.currently_active.count ],
        [ "Abonnements expirés", company.contract_periods.expired.count ],
        [ "Membres d'équipe", company.staff_members.count ]
      ]
    end

    def paid_payments_in_period
      @paid_payments_in_period ||= company.payments.paid.where(paid_at: period.range)
    end

    def revenue_total
      paid_payments_in_period.sum(:amount)
    end

    def revenue_by_method
      @revenue_by_method ||= paid_payments_in_period.group(:payment_method).sum(:amount)
    end

    def payments_received_by_client
      @payments_received_by_client ||= paid_payments_in_period.group(:client_id).sum(:amount)
    end

    def build_clients_sheet
      package.workbook.add_worksheet(name: "Clients") do |sheet|
        sheet.add_row [ "Nom complet", "Téléphone", "Email", "Statut", "Date d'inscription", "Paiements reçus (#{period.label})" ],
                      style: Array.new(6, header_style)

        company.memberships.includes(:client).joins(:client).order("clients.first_name", "clients.last_name").find_each do |membership|
          client = membership.client
          status_style = membership.active? ? active_style : inactive_style
          sheet.add_row [
            client.full_name,
            client.phone,
            client.email,
            membership.active? ? "Actif" : "Inactif",
            membership.joined_at&.to_date,
            payments_received_by_client[client.id] || 0
          ], style: [ nil, nil, nil, status_style, nil, nil ]
        end

        sheet.column_widths 24, 16, 26, 12, 18, 20
      end
    end
  end
end
