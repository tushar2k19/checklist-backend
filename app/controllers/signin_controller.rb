class SigninController < ApplicationController
  # POST /signin
  def create
    user = User.find_by(email: params[:email])
    if user&.authenticate(params[:password])
      payload = { user_id: user.id }
      session = JWTSessions::Session.new(payload: payload, refresh_by_access_allowed: true)
      tokens = session.login

      # Trigger file lifecycle cleanup job after successful login
      trigger_file_cleanup

      render json: {
        success: true,
        access: tokens[:access],
        csrf: tokens[:csrf],
        user: {
          id: user.id,
          first_name: user.first_name,
          last_name: user.last_name,
          email: user.email,
          role: user.role
        }
      }
    else
      render json: { error: 'Invalid email or password' }, status: :unauthorized
    end
  end

  # DELETE /signout
  def destroy
    begin
      session = JWTSessions::Session.new(payload: payload)
      session.flush_by_access_payload
      render json: { message: 'Logged out successfully' }, status: :ok
    rescue JWTSessions::Errors::Unauthorized
      render json: { error: 'Not authorized' }, status: :unauthorized
    end
  end

  private

  def trigger_file_cleanup
    # Check if cleanup is enabled (default: enabled)
    cleanup_enabled = ENV['ENABLE_FILE_CLEANUP_ON_LOGIN'].blank? || ENV['ENABLE_FILE_CLEANUP_ON_LOGIN'] == 'true'
    
    unless cleanup_enabled
      Rails.logger.info "[SigninController] File cleanup on login is disabled (ENABLE_FILE_CLEANUP_ON_LOGIN=false)"
      return
    end
    
    # Check for expired files for ALL users
    expired_count = UploadedFile.expired_for_cleanup.count
    
    if expired_count > 0
      Rails.logger.info "=" * 80
      Rails.logger.info "[SigninController] ===== TRIGGERING FILE LIFECYCLE CLEANUP ====="
      Rails.logger.info "[SigninController] User logged in successfully"
      Rails.logger.info "[SigninController] Found #{expired_count} expired file(s) that need cleanup (system-wide)"
      Rails.logger.info "[SigninController] Queuing FileLifecycleCleanupJob..."
      FileLifecycleCleanupJob.perform_later
      Rails.logger.info "[SigninController] File cleanup job queued successfully (will run in background)"
      Rails.logger.info "=" * 80
    else
      Rails.logger.info "[SigninController] No expired files found. Cleanup job not needed."
    end
  end
end



