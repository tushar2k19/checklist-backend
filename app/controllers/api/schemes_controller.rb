module Api
  class SchemesController < ApplicationController
    before_action :authenticate_user!

    # GET /api/schemes
    def index
      schemes = Scheme.ordered
      render_success(
        { schemes: schemes.as_json(only: [:id, :name]) },
        message: "Schemes retrieved successfully"
      )
    end
  end
end


