# frozen_string_literal: true

module AntiAbuse
  class UniqueDetumbledEmailValidator < ActiveModel::Validator
    NORMALIZED_EMAIL_ACCOUNT_LIMIT = 5

    def validate(record)
      return if record.errors.include?(:email)

      email = record.email

      return unless prevent_banned_user_email_reuse?(email) || limit_normalized_email_reuse?(email)

      record.errors.add(:email, _('is not allowed. Please enter a different email address and try again.'))
    end

    private

    def prevent_banned_user_email_reuse?(email)
      return false unless ::Feature.enabled?(:block_banned_user_normalized_email_reuse, ::Feature.current_request)

      ::Users::BannedUser.by_detumbled_email(email).exists?
    end

    def limit_normalized_email_reuse?(email)
      return false unless ::Feature.enabled?(:limit_normalized_email_reuse, ::Feature.current_request)

      Email.users_by_detumbled_email_count(email) >= NORMALIZED_EMAIL_ACCOUNT_LIMIT
    end
  end
end

AntiAbuse::UniqueDetumbledEmailValidator.prepend_mod
