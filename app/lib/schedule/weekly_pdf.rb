require "prawn"
require "prawn/table"

Prawn::Fonts::AFM.hide_m17n_warning = true

module Schedule
  # Printable weekly planning, one page per coach — the thing a coach takes
  # to the floor or pins in the staff room. Same letterhead/palette as
  # Receipts::ContractPdf so every document Fitora prints looks like it
  # came from the same product.
  class WeeklyPdf
    INK = "1A1330".freeze
    GREY = "6B6386".freeze
    LINE = "D9D2E6".freeze
    HAIR = "999999".freeze
    ACCENT = "E8005F".freeze

    DAY_NAMES = %w[Lundi Mardi Mercredi Jeudi Vendredi Samedi Dimanche].freeze

    def self.call(company:, week_start:, sessions:)
      new(company: company, week_start: week_start, sessions: sessions).call
    end

    def initialize(company:, week_start:, sessions:)
      @company = company
      @week_start = week_start
      @week_end = week_start + 6.days
      # Coaches sorted by name; sessions with no coach assigned form their
      # own trailing group rather than being silently dropped.
      @by_coach = sessions.sort_by(&:starts_at).group_by(&:coach).sort_by { |coach, _| coach&.full_name || "￿" }
    end

    def call
      Prawn::Document.new(page_size: "A4", page_layout: :landscape, margin: 40) do |pdf|
        @by_coach.each_with_index do |(coach, sessions), index|
          pdf.start_new_page unless index.zero?
          letterhead(pdf, coach)
          sessions_table(pdf, sessions)
          page_footer(pdf, coach)
        end
      end.render
    end

    private

    attr_reader :company, :week_start, :week_end

    def coach_full_name(coach)
      return "Sans coach assigné" if coach.nil?

      coach.full_name
    end

    # ---- letterhead ---------------------------------------------------------
    def letterhead(pdf, coach)
      top = pdf.cursor
      half = pdf.bounds.width / 2

      pdf.fill_color INK
      pdf.text_box company.name, at: [ 0, top ], width: half, size: 20, style: :bold
      pdf.fill_color ACCENT
      pdf.text_box "PLANNING HEBDOMADAIRE", at: [ 0, top - 26 ], width: half, size: 10, style: :bold
      pdf.fill_color "000000"

      pdf.fill_color GREY
      pdf.text_box "#{fmt_date(week_start)} — #{fmt_date(week_end)}", at: [ half, top ], width: half, align: :right, size: 11
      pdf.text_box company.name, at: [ half, top - 16 ], width: half, align: :right, size: 9
      pdf.fill_color "000000"

      pdf.move_cursor_to top - 44
      pdf.fill_color ACCENT
      pdf.text coach_full_name(coach), size: 16, style: :bold
      pdf.fill_color "000000"

      pdf.move_down 10
      pdf.stroke_color HAIR
      pdf.stroke_horizontal_rule
      pdf.stroke_color "000000"
      pdf.move_down 18
    end

    # ---- one row per session, grouped visually by day ---------------------
    def sessions_table(pdf, sessions)
      if sessions.empty?
        pdf.fill_color GREY
        pdf.text "Aucune séance planifiée cette semaine.", size: 11
        pdf.fill_color "000000"
        return
      end

      head = [ "Jour", "Heure", "Activité", "Format", "Lieu", "Inscrits", "Statut" ]
      rows = sessions.map { |s| session_row(s) }

      pdf.table([ head ] + rows, width: pdf.bounds.width, column_widths: column_widths(pdf)) do |t|
        t.cells.borders = []
        t.cells.padding = [ 8, 8 ]
        t.cells.size = 10
        t.cells.valign = :center

        t.row(0).borders = [ :bottom ]
        t.row(0).border_color = HAIR
        t.row(0).font_style = :bold
        t.row(0).text_color = GREY

        t.rows(1..-1).borders = [ :bottom ]
        t.rows(1..-1).border_color = LINE

        t.column(5).align = :center
        t.column(6).align = :center
      end
    end

    def column_widths(pdf)
      w = pdf.bounds.width
      { 0 => w * 0.13, 1 => w * 0.12, 2 => w * 0.22, 3 => w * 0.15, 4 => w * 0.16, 5 => w * 0.11, 6 => w * 0.11 }
    end

    def session_row(session)
      [
        day_label(session.starts_at),
        "#{fmt_time(session.starts_at)}–#{fmt_time(session.ends_at)}",
        session.activity.name,
        format_label(session.activity.session_format),
        session.company.name,
        "#{session.confirmed_bookings_count}/#{session.capacity}",
        status_label(session.status)
      ]
    end

    def day_label(time)
      DAY_NAMES[time.wday.zero? ? 6 : time.wday - 1]
    end

    def format_label(format)
      { "individual" => "Individuel", "small_group" => "Petit groupe", "collective" => "Collectif" }.fetch(format, format)
    end

    def status_label(status)
      { "scheduled" => "Prévue", "cancelled" => "Annulée", "completed" => "Terminée" }.fetch(status, status)
    end

    # ---- footer, anchored to the bottom of the page -----------------------
    def page_footer(pdf, coach)
      pdf.canvas do
        x = pdf.bounds.left + 40
        w = pdf.bounds.width - 80
        pdf.stroke_color LINE
        pdf.horizontal_line x, x + w, at: 40
        pdf.stroke
        pdf.stroke_color "000000"

        pdf.fill_color GREY
        pdf.text_box "Édité avec le logiciel Fitora · #{coach_full_name(coach)}",
                     at: [ x, 32 ], width: w, align: :center, size: 8
        pdf.text_box "Généré le #{fmt_date(Time.current)} à #{fmt_time(Time.current)}",
                     at: [ x, 20 ], width: w, align: :center, size: 7
        pdf.fill_color "000000"
      end
    end

    def fmt_date(value)
      value&.to_date&.strftime("%d/%m/%Y") || "—"
    end

    def fmt_time(value)
      value&.strftime("%H:%M") || "—"
    end
  end
end
