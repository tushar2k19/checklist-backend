# frozen_string_literal: true

module Api
  class PasswordsController < ApplicationController
    before_action :authenticate_user!

    # PATCH /api/passwords
    def update
      current_password = params[:current_password]
      new_password = params[:new_password]
      new_password_confirmation = params[:new_password_confirmation]

      if current_password.blank?
        return render_error('validation_error', 'Current password is required', status: :unprocessable_entity)
      end

      if new_password.blank?
        return render_error('validation_error', 'New password is required', status: :unprocessable_entity)
      end

      if new_password.length < 6
        return render_error('validation_error', 'New password must be at least 6 characters', status: :unprocessable_entity)
      end

      if new_password != new_password_confirmation
        return render_error('validation_error', 'New password and confirmation do not match', status: :unprocessable_entity)
      end

      unless current_user.authenticate(current_password)
        return render_error('invalid_password', 'Current password is incorrect', status: :unprocessable_entity)
      end

      current_user.update!(password: new_password, password_confirmation: new_password_confirmation)

      render_success(
        { message: 'Password updated successfully' },
        message: 'Password updated successfully'
      )
    rescue ActiveRecord::RecordInvalid => e
      render_error('validation_error', e.record.errors.full_messages.join(', '), status: :unprocessable_entity)
    end
  end
end
