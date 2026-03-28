require 'sidekiq/web'  

Rails.application.routes.draw do
  namespace :api do
    namespace :v1 do
      resources :requests, only: [:create, :show, :destroy]
    end
  end

  mount Sidekiq::Web => '/sidekiq'
end
