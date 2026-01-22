Rails.application.routes.draw do
  get "up" => "rails/health#show", as: :rails_health_check
  get 'test_auth' => 'application#test_auth'
  
  # Auth
  post '/signin', to: 'signin#create'
  delete '/signout', to: 'signin#destroy'
  
  # API Namespace
  namespace :api do
    # File Management
    resources :files, only: [:index, :create, :show, :destroy] do
      member do
        get :status
      end
    end
    
    # Metadata
    resources :schemes, only: [:index]
    resources :document_types, only: [:index]
    
    # Checklist Templates
    resources :checklist_templates, only: [:index]
    
    # Evaluations
    resources :evaluations, only: [:index, :create, :show, :destroy]
    
    # Legacy/Deprecated (to be removed)
    post 'checklist/analyze', to: 'checklist#analyze'
    get 'checklist/defaults', to: 'checklist#defaults'
    end

  # Health Check
  get '/api/health', to: proc { [200, { 'Content-Type' => 'application/json' }, [{ status: 'healthy' }.to_json]] }
end
