module Api
  module V1
    # CSV import/export for the four entities an admin most often needs to
    # move in bulk (migrating from another tool, or backing data out). See
    # DataExchange::REGISTRY for the strategies and the capabilities.
    class DataExchangeController < BaseController
      before_action :require_company!
      before_action :set_strategy!, except: [ :show_import ]
      before_action :set_import!, only: [ :show_import ]

      # GET /api/v1/data_exchange/:entity/template
      def template
        send_data @strategy.template_csv, filename: "fitora-#{params[:entity]}-modele.csv", type: "text/csv"
      end

      # GET /api/v1/data_exchange/:entity/export
      def export
        send_data @strategy.export_csv(current_company), filename: "fitora-#{params[:entity]}-export.csv", type: "text/csv"
      end

      # POST /api/v1/data_exchange/:entity/import (multipart, field "file")
      #
      # Stores the file and hands it to DataImportJob; the answer is the
      # import to poll, not its result. Capped at DataImport::MAX_BYTES and
      # DataImport::MAX_ROWS.
      def import
        import = current_company.data_imports.new(entity: params[:entity], user: current_user)
        import.file.attach(params[:file]) if params[:file].present?

        if import.save
          DataImportJob.perform_later(import.id)
          render json: import_json(import), status: :accepted
        else
          render_errors(import)
        end
      end

      # GET /api/v1/data_exchange/imports/:id
      def show_import
        render json: import_json(@import)
      end

      private

      def set_strategy!
        @strategy = DataExchange::REGISTRY[params[:entity]]
        return render json: { error: "Unknown entity: #{params[:entity]}" }, status: :not_found unless @strategy

        require_capability!(params[:entity])
      end

      # Readable by whoever may manage what it imports.
      def set_import!
        @import = current_company.data_imports.find(params[:id])
        require_capability!(@import.entity)
      end

      def import_json(import)
        {
          id: import.id, entity: import.entity, status: import.status, finished: import.finished?,
          created: import.created_count, errors: import.row_errors, message: import.message
        }
      end
    end
  end
end
