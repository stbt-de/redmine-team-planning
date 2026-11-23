# frozen_string_literal: true

# Seiten: Board, Abschluss, Teamrunde. Die Person wählt ?user_id=.
# Änderungen auf dem Board antworten mit JSON (Hinweis und Rückgängig);
# das Format bleibt bewusst offen, sonst hielte Redmine die Anfrage für
# einen API-Aufruf und ignorierte die Sitzung.
get 'team_planning', to: 'team_planning#show', as: 'team_planning'
get 'team_planning/close', to: 'team_planning#close', as: 'team_planning_close'
post 'team_planning/close', to: 'team_planning#close_period'
get 'team_planning/team', to: 'team_planning#team', as: 'team_planning_team'
patch 'team_planning/round', to: 'team_planning#update_round', as: 'team_planning_round'
patch 'team_planning/settings', to: 'team_planning#settings', as: 'team_planning_settings'

scope 'team_planning' do
  post 'issues', to: 'team_planning_items#create', as: 'team_planning_issues'
  patch 'periods/:starts_on/absence', to: 'team_planning_items#absence', as: 'team_planning_absence',
                                      constraints: { starts_on: /\d{4}-\d{2}-\d{2}/ }
  scope 'issues/:issue_id', constraints: { issue_id: /\d+/ } do
    post 'move', to: 'team_planning_items#move', as: 'team_planning_move'
    patch '', to: 'team_planning_items#update', as: 'team_planning_item'
    get 'done_options', to: 'team_planning_items#done_options', as: 'team_planning_done_options'
    post 'complete', to: 'team_planning_items#complete', as: 'team_planning_complete'
    post 'reopen', to: 'team_planning_items#reopen', as: 'team_planning_reopen'
    post 'unassign', to: 'team_planning_items#unassign', as: 'team_planning_unassign'
    post 'end_standing', to: 'team_planning_items#end_standing', as: 'team_planning_end_standing'
    post 'time', to: 'team_planning_items#log_time', as: 'team_planning_log_time'
    delete 'time/:id', to: 'team_planning_items#destroy_time', as: 'team_planning_time_entry', constraints: { id: /\d+/ }
  end
end
