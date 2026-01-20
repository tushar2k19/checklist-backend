module Api
  class ChecklistController < ApplicationController
  before_action :authenticate_user!
  
    # POST /api/checklist/analyze
    # Deprecated: Use EvaluationsController#create instead
    def analyze
      render_error(
        "deprecated_endpoint",
        "This endpoint is deprecated. Please use POST /api/evaluations",
        status: :gone
      )
    end
    
    # GET /api/checklist/defaults
    # Deprecated: Use ChecklistTemplatesController#index instead
    def defaults
      render_error(
        "deprecated_endpoint",
        "This endpoint is deprecated. Please use GET /api/checklist_templates",
        status: :gone
      )
    end
  end
end
