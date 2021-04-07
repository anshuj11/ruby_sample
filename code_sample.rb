#### This snippet is from an application
#### Which integrates multiple APIs from third party
# Using web-sockets for async communication is required
# because of longer response time on the API endpoints being accessed

filename: agreements_controller.rb
    def create_docs
      status = params["payload"]["status"]
      target = params["payload"]["target"]
      Occ::CreateSignService.perform_later(@account.selected_quote, status, target)

      render json: { success: true }
    end

 ##########  filename: create_sign_service.rb    
  class CreateSignService < ApplicationJob
    queue_as :docs_to_sign

    def status?(status)
      status != "" && !status.nil?
    end

    def build_payload(success, response, error)
      payload = {}
      payload[:success] = success
      if success
        payload[:response] = response
      else
        payload[:error] = error
      end
      payload
    end

    def perform(selected_quote, status, target)
      fetch_valid_agreement(selected_quote) unless status?(status)
      api = SignDocsAPI.new(selected_quote)
      api.call
      response = api.response
      response[:target] = target
      payload = build_payload(true, response, nil)
      broadcast_client_data(selected_quote, payload)
    rescue RestClient::Exception => e
      Rails.logger.error "[ODC::DOCUSIGN_ENVELOPE][CREATE_FAILED] #{e.message}"
      payload = build_payload(false, nil, e.message)
      broadcast_client_data(selected_quote, payload)
    end

    def broadcast_client_data(selected_quote, response)
      Rails.logger.info "WebSocket BROADCASTING 'occ:DocsAPI:QuoteId:#{selected_quote}', response: #{response}"
      ActionCable.server.broadcast "occ:create_docs:#{selected_quote}", response
    end

    def fetch_valid_agreement(selected_quote)
      api = SignAgreementAPI.new(selected_quote)
      api.call
    end
  end
end

############## sign_agreement_api.rb ##################
class SignAgreementAPI < SomeAPI
  attr_accessor :qid
  ODC_AGREEMENT_URL = "some/url".freeze
  def initialize(qid, options = {})
    @qid = qid
    super(options)
  end

  def default_options
    super.deep_merge(
      method: :get,
      action: "#{ODC_AGREEMENT_URL}/#{qid}"
    )
  end

  def mocked_response
    file = "fixtures/agreement_response.json"
    OpenStruct.new(
      code: 200,
      body: File.read(file)
    )
  end
end
############## sign_docs_api.rb ##################
class SignDocsAPI < SomeAPI
  attr_accessor :qid
  ODC_DOCS_URL = "URL".freeze
  def initialize(qid, options = {})
    @qid = qid
    super(options)
  end

  def default_options
    super.deep_merge(
      method: :get,
      action: "#{ODC_DOCS_URL}/#{qid}"
    )
  end

  def mocked_response
    sleep(5)
    file = "fixtures/docs_response.json"

    OpenStruct.new(
      code: 200,
      body: File.read(file)
    )
  end
end

######################### create_docs_channel.rb ###################
module Occ
  # A WebSocket channel for communicating data based on /envelope API call to SF
  class CreateDocsChannel < ApplicationCable::Channel
    def subscribed
      Rails.logger.info "WebSocket SUBSCRIBED 'occ:agreement:createDocsChannel:#{params[:qid]}'"
      stream_for params[:qid]
    end

    def unsubscribed
      Rails.logger.info "WebSocket UNSUBSCRIBED 'occ:agreement:createDocsChannel:#{params[:qid]}'"
      # Any cleanup needed when channel is unsubscribed
    end
  end
end

############################# Tests ###########################################
###########Written in minitest################################
#i#########agreements_controller_test.rb ####################
      test "calls to Occ::DocsSignService to return docs" do
        params = {
          id_token: @id_token,
          payload: {
            status: 'Draft',
            target: 'Membership Documents'
          }
        }
        actual_response = {
          success: true
        }.to_json

        docs_sign_service_mock = mock
        docs_sign_service_mock.stubs(:perform_later).returns(actual_response)
        docs_sign_service_mock.expects(:enqueue).returns(anything)
        Occ::DocsSignService.expects(:new).returns(docs_sign_service_mock)

        post create_docs_occ_contract_path params: params
        assert_equal response.body, actual_response
        assert_response :success
      end

