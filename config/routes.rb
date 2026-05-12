Rails.application.routes.draw do
  devise_for :users

  root "pages#home"

  resource :dashboard, only: [:show]

  resource :cart, only: [:show] do
    post :add
    patch :update_item
    delete :remove_item
    delete :clear
  end

  resources :orders, only: [:new, :create, :show, :index] do
    post :repeat, on: :member
  end

  namespace :admin do
    get 'production/index'
    root "dashboard#show"
    resources :orders, only: [:index, :show]
    resources :production, only: [:index, :show]  
    resources :products
    resources :categories
  end
end