class PublicActivity::ActivityPolicy
  class Scope
    attr_reader :user, :scope

    def initialize(user, scope)
      @user = user
      @scope = scope
    end

    def resolve
      # Show Team events only if user is a member of the team
      team_activities = @scope
        .joins("INNER JOIN teams ON activities.trackable_id = teams.id " \
               "INNER JOIN team_users ON teams.id = team_users.team_id")
        .where("activities.trackable_type = ? AND team_users.user_id = ?",
               "Team", user.id)

      # Show Namespace events only if user is a member of the team controlling
      # the namespace or if the event is a public <-> private switch.
      namespace_activities = @scope
        .joins("INNER JOIN namespaces ON activities.trackable_id = namespaces.id " \
               "INNER JOIN teams ON teams.id = namespaces.team_id " \
               "INNER JOIN team_users ON teams.id = team_users.team_id")
        .where("activities.trackable_type = ? AND " \
               "(team_users.user_id = ? OR " \
               "((activities.key = ? OR activities.key = ?) AND namespaces.public = ?))",
               "Namespace", user.id, "namespace.public", "namespace.private", true)

      # Show tag events for repositories inside of namespaces controller by
      # a team the user is part of, or tags part of public namespaces.
      repository_activities = @scope
        .joins("INNER JOIN repositories ON activities.trackable_id = repositories.id " \
               "INNER JOIN namespaces ON namespaces.id = repositories.namespace_id " \
               "INNER JOIN teams ON namespaces.team_id = teams.id " \
               "INNER JOIN team_users ON teams.id = team_users.team_id")
        .where("activities.trackable_type = ? AND " \
               "(team_users.user_id = ? OR namespaces.public = ?)",
               "Repository", user.id, true)

      # Show application tokens activities related only to the current user
      application_token_activities = @scope
        .where("activities.trackable_type = ? AND activities.owner_id = ?",
               "ApplicationToken", user.id)

      # Show webhook events only if user is a member of the team controlling
      # the namespace.
      # Note: this works only for existing webhooks
      webhook_activities = @scope
        .joins("INNER JOIN webhooks ON activities.trackable_id = webhooks.id " \
               "INNER JOIN namespaces ON namespaces.id = webhooks.namespace_id " \
               "INNER JOIN teams ON teams.id = namespaces.team_id " \
               "INNER JOIN team_users ON teams.id = team_users.team_id")
        .where("activities.trackable_type = ? AND team_users.user_id = ?",
               "Webhook", user.id)

      # Convert relation to array since we want to add single objects, and objects
      # cannot be added to relations.
      webhook_activities = webhook_activities.to_a

      # Get all namespaces the user has access to.
      user_namespaces = Namespace
        .where(team_id: TeamUser.where(user_id: user.id).pluck(:team_id))
        .pluck(:id)

      # Go through all webhooks and add those to the array whose namespace_id is
      # included in the user's accessible namespaces.
      @scope
        .joins("INNER JOIN namespaces ON activities.trackable_id = namespaces.id " \
               "INNER JOIN teams ON teams.id = namespaces.team_id " \
               "INNER JOIN team_users ON teams.id = team_users.team_id")
        .where("activities.trackable_type = ?", "Webhook").distinct.find_each do |webhook|
          unless webhook.parameters.empty?
            if user_namespaces.include? webhook.parameters[:namespace_id]
              webhook_activities << webhook
            end
          end
        end

      # "convert" array back to relation in order to use `union_all`.
      webhook_activities = @scope.where(id: webhook_activities.map(&:id))

      team_activities
        .union_all(namespace_activities)
        .union_all(repository_activities)
        .union_all(application_token_activities)
        .union_all(webhook_activities)
        .distinct
    end
  end
end
