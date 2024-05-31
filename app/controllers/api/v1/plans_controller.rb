# frozen_string_literal: true

module Api
  module V1
    # Handles CRUD operations for plans in API V1
    class PlansController < BaseApiController
      respond_to :json

      # GET /api/v1/plans/:id
      def show
        plans = Api::V1::PlansPolicy::Scope.new(client, Plan).resolve
                                           .where(id: params[:id]).limit(1)

        if plans.present? && plans.any?
          @items = paginate_response(results: plans)
          render '/api/v1/plans/index', status: :ok
        else
          render_error(errors: [_('Plan not found')], status: :not_found)
        end
      end

      # POST /api/v1/plans
      # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
      # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
      def create
        dmp = @json.with_indifferent_access.fetch(:items, []).first.fetch(:dmp, {})

        # Do a pass through the raw JSON and check to make sure all required fields
        # were present. If not, return the specific errors
        errs = Api::V1::JsonValidationService.validation_errors(json: dmp)
        render_error(errors: errs, status: :bad_request) and return if errs.any?

        # Convert the JSON into a Plan and it's associations
        plan = Api::V1::Deserialization::Plan.deserialize(json: dmp)
        if plan.present?
          save_err = _('Unable to create your DMP')
          exists_err = _('Plan already exists. Send an update instead.')
          no_org_err = _("Could not determine ownership of the DMP. Please add an
                          :affiliation to the :contact")

          # Try to determine the Plan's owner
          owner = determine_owner(client: client, plan: plan)
          plan.org = owner.org if owner.present? && plan.org.blank?
          render_error(errors: no_org_err, status: :bad_request) and return unless plan.org.present?

          # Validate the plan and it's associations and return errors with context
          # e.g. 'Contact affiliation name can't be blank' instead of 'name can't be blank'
          errs = Api::V1::ContextualErrorService.process_plan_errors(plan: plan)

          # The resulting plan (our its associations were invalid)
          render_error(errors: errs, status: :bad_request) and return if errs.any?
          # Skip if this is an existing DMP
          render_error(errors: exists_err, status: :bad_request) and return unless plan.new_record?

          # If we cannot save for some reason then return an error
          plan = Api::V1::PersistenceService.safe_save(plan: plan)
          render_error(errors: save_err, status: :internal_server_error) and return if plan.new_record?

          # If the plan was generated by an ApiClient then associate them
          plan.update(api_client_id: client.id) if client.is_a?(ApiClient)

          # Invite the Owner if they are a Contributor then attach the Owner to the Plan
          owner = invite_contributor(contributor: owner) if owner.is_a?(Contributor)
          plan.add_user!(owner.id, :creator)

          # Kaminari Pagination requires an ActiveRecord result set :/
          @items = paginate_response(results: Plan.where(id: plan.id))
          render '/api/v1/plans/index', status: :created
        else
          render_error(errors: [_('Invalid JSON!')], status: :bad_request)
        end
      rescue JSON::ParserError
        render_error(errors: [_('Invalid JSON')], status: :bad_request)
      end
      # rubocop:enable Metrics/AbcSize, Metrics/MethodLength
      # rubocop:enable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

      # GET /api/v1/plans
      def index
        # ALL can view: public
        # ApiClient can view: anything from the API client
        # User (non-admin) can view: any personal or organisationally_visible
        # User (admin) can view: all from users of their organisation
        plans = Api::V1::PlansPolicy::Scope.new(client, Plan).resolve
        if plans.present? && plans.any?
          @items = paginate_response(results: plans)
          @minimal = true
          render 'api/v1/plans/index', status: :ok
        else
          render_error(errors: [_('No Plans found')], status: :not_found)
        end
      end

      private

      def dmp_params
        params.require(:dmp).permit(plan_permitted_params).to_h
      end

      def plan_exists?(json:)
        return false unless json.present? &&
                            json[:dmp_id].present? &&
                            json[:dmp_id][:identifier].present?

        scheme = IdentifierScheme.by_name(json[:dmp_id][:type]).first
        Identifier.where(value: json[:dmp_id][:identifier], identifier_scheme: scheme).any?
      end

      # Get the Plan's owner
      def determine_owner(client:, plan:)
        contact = plan.contributors.find(&:data_curation?)
        # Use the contact if it was sent in and has an affiliation defined
        return contact if contact.present? && contact.org.present?

        # If the contact has no affiliation defined, see if they are already a User
        user = lookup_user(contributor: contact)
        return user if user.present?

        # Otherwise just return the client
        client
      end

      def lookup_user(contributor:)
        return nil unless contributor.present?

        identifiers = contributor.identifiers.map do |id|
          { name: id.identifier_scheme&.name, value: id.value }
        end
        user = User.from_identifiers(array: identifiers) if identifiers.any?
        user = User.find_by(email: contributor.email) unless user.present?
        user
      end

      # rubocop:disable Metrics/AbcSize
      def invite_contributor(contributor:)
        return nil unless contributor.present?

        # If the user was not found, invite them and attach any know identifiers
        names = contributor.name&.split || ['']
        firstname = names.length > 1 ? names.first : nil
        surname = names.length > 1 ? names.last : names.first
        user = User.invite!({ email: contributor.email,
                              firstname: firstname,
                              surname: surname,
                              org: contributor.org }, client)

        contributor.identifiers.each do |id|
          user.identifiers << Identifier.new(
            identifier_scheme: id.identifier_scheme, value: id.value
          )
        end
        user
      end
      # rubocop:enable Metrics/AbcSize
    end
  end
end