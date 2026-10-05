# Serves the Angular single-page app. The Dockerfile bakes the production
# build into public/; in development there is no build there, so this falls
# back to a plain message (run the Angular dev server on :4200 instead).
class SpaController < ActionController::API
  def index
    index_html = Rails.public_path.join("index.html")

    if index_html.file?
      send_file index_html, type: "text/html", disposition: "inline"
    else
      render json: { service: "fitora-api", spa: "not built in this environment" }, status: :ok
    end
  end
end
