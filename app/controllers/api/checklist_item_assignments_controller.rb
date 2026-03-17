module Api
  class ChecklistItemAssignmentsController < ApplicationController
    before_action :authenticate_user!
    before_action :set_assignment, only: [:destroy]

    # DELETE /api/checklist_item_assignments/:id
    def destroy
      @assignment.destroy!
      render_success(
        { message: "Checklist item removed from scheme" },
        message: "Checklist item removed successfully"
      )
    end

    private

    def set_assignment
      @assignment = ChecklistItemSchemeAssignment.find(params[:id])
    end
  end
end
