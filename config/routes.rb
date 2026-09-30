# frozen_string_literal: true

PlanDriven::Wizard::Engine.routes.draw do
  root "plans#index"
  resources :plans, only: %i[new create], param: :key
  get "plans/:key(/:step)", to: "plans#show", as: :plan, constraints: { step: /plan|approve|tickets|agents|finish/ }
  post "plans/:key/run", to: "plans#run", as: :run_plan
  get "plans/:key/files/:name", to: "plans#file", as: :plan_file, constraints: { name: /[a-z-]+\.(pdf|html)/ }
  post "run", to: "plans#run_global", as: :run
  post "actor", to: "plans#actor", as: :actor
  get "jobs/:id", to: "jobs#show", as: :job
end
