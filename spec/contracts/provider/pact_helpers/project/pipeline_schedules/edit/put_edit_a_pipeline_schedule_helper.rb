# frozen_string_literal: true

require_relative "../../../../spec_helper"
require_relative "../../../../helpers/contract_source_helper"
require_relative "../../../../helpers/publish_contract_helper"
require_relative "../../../../states/project/pipeline_schedules/edit_state"

module Provider
  module CreateNewPipelineHelper
    Pact.service_provider "PUT edit a pipeline schedule" do
      app { Environments::Test.app }

      honours_pact_with "PipelineSchedules#edit" do
        pact_uri Provider::ContractSourceHelper.contract_location(:spec, __FILE__)
      end

      Provider::PublishContractHelper.publish_contract_setup.call(
        method(:app_version),
        method(:app_version_branch),
        method(:publish_verification_results)
      )
    end
  end
end
