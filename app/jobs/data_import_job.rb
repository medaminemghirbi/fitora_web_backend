# Works through one uploaded CSV (DataImport). Row errors are the import's
# result, not the job's failure: a bad row is reported and the rest carry on.
class DataImportJob < ApplicationJob
  queue_as :default

  def perform(import_id)
    import = DataImport.find_by(id: import_id)
    return if import.nil? || import.finished?

    import.running!
    content = import.file.download.force_encoding(Encoding::UTF_8)
    rows = CSV.parse(content, headers: true).size
    if rows > DataImport::MAX_ROWS
      return import.update!(status: :failed, message: "#{rows} rows is more than the #{DataImport::MAX_ROWS} one import takes. Split the file.")
    end

    result = Time.use_zone(import.company.time_zone) do
      import.strategy.import_csv(company: import.company, user: import.user, io: StringIO.new(content))
    end
    import.update!(status: :done, created_count: result[:created], row_errors: result[:errors])
    record_audit(import) if result[:created].positive?
  rescue CSV::MalformedCSVError => e
    import.update!(status: :failed, message: "Invalid CSV file: #{e.message}")
  ensure
    import&.file&.purge_later if import&.finished?
  end

  private

  def record_audit(import)
    AuditLog.record!(
      company: import.company, user: import.user, action: "data.imported", auditable: import.company,
      metadata: { entity: import.entity, created: import.created_count, error_count: import.row_errors.size }
    )
  end
end
