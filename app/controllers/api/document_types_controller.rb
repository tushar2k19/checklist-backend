module Api
  class DocumentTypesController < ApplicationController
    before_action :authenticate_user!

    # GET /api/document_types
    def index
      doc_types = DocumentType.ordered
      render_success(
        { document_types: doc_types.as_json(only: [:id, :name]) },
        message: "Document types retrieved successfully"
      )
    end
  end
end


