require "dry/monads"
require "amazing_print"
require "pry"

RSpec.describe "Tasks w/ Logging" do
  include Dry::Monads[:task, :result]

  let(:log) do
    -> (event, a) {
      thread_name = Thread.current.name || "main"
      timestamp = Process.clock_gettime(Process::CLOCK_MONOTONIC, :microsecond)
      puts(thread: thread_name, occured_at: timestamp, event: event, payload: a)

      a 
    }
  end
  let(:pbm_workflow) do
    ->(rtpbi_request) {
      prepare_request = -> (rtpbi_request) {
        head, *tail = rtpbi_request.split("::")
        Success("pbm_request::" + tail.join("::"))
      }
      send_request = -> (pbm_request) {
       head, *tail = pbm_request.split("::")
       Success("pbm_response::" + tail.join("::")) 
      }
      prepare_response = -> (pbm_response) {
        head, *tail = pbm_response.split("::")
        Success("rtpbi_response::" + tail.join("::")) 
      }

      Success(rtpbi_request)
        .fmap { |it| log.("pbm_workflow::request_received", it) }
        .bind(prepare_request)
        .fmap { |it| log.("pbm_workflow::request_prepared", it) }
        .fmap { |it| log.("pbm_workflow::request_sent", it) }
        .fmap { |it| sleep 3; it }
        .bind(send_request)
        .fmap { |it| log.("pbm_workflow::response_received", it) }
        .bind(prepare_response)
        .fmap { |it| log.("pbm_workflow::response_prepared", it) }
    }
  end
  let(:guide_workflow) do
    ->(workflow, rtpbi_request) {
      prepare_request = ->(rtpbi_request) {
        head, *tail = rtpbi_request.split("::")
        Success(head + "::guide_request::" + tail.join("::"))
      }
      send_request = ->(guide_rtpbi_request) {
        workflow.(guide_rtpbi_request)
      }
      prepare_response = ->(guide_pbm_response) {
        head, _, *tail = guide_pbm_response.split("::")
        Success(head + "::guide_response::" + tail.join("::"))
      }
      
      Success(rtpbi_request)
        .fmap { |it| log.("guide_workflow::request_received", it) }
        .bind(prepare_request)
        .fmap { |it| log.("guide_workflow::request_prepared", it) }
        .fmap { |it| log.("guide_workflow::request_sent", it) }
        .bind(send_request)
        .fmap { |it| log.("guide_workflow::response_received", it) }
        .bind(prepare_response) 
        .fmap { |it| log.("guide_workflow::response_prepared", it) }
    }
  end
  let(:good_rx_workflow) do
    ->(rtpbi_request) {
      Success(rtpbi_request)
        .fmap { |it| log.("good_rx_workflow::request_received", it) }
        .fmap { |it| sleep 2; it }
        .fmap { "good_rx::response" }
        .fmap { |it| log.("good_rx_workflow::response_received", it) }
    }
  end
  let(:gaps_in_care_workflow) do
    -> (rtpbi_request) {
      Success(rtpbi_request)
        .fmap { |it| log.("gaps_in_care_workflow::request_received", it) }
        .fmap { |it| sleep 4; it }
        .fmap { "gaps_in_care::response" }
        .fmap { |it| log.("gaps_in_care_workflow::response_received", it) }
    }
  end
  let(:combine_good_rx) do
    fn = ->(preferred_result, good_rx_result) {
      preferred_result.and(good_rx_result) { |preferred_value, good_rx_value|
        [preferred_value, good_rx_value].join(", ")
      }
      .or {
        preferred_result.or(good_rx_result)
      }
    }

    ->(preferred_task, good_rx_task) {
      compose_tasks.(fn, preferred_task, good_rx_task)
    }
  end
  let(:combine_guide) do
    fn = ->(preferred_result, guide_result) {
      preferred_result.and(guide_result) { |preferred_value, guide_value|
        [preferred_value, guide_value].join(", ")
      }
      .or {
        preferred_result
      }
    }

    ->(preferred_task, guide_task) {
      compose_tasks.(fn, preferred_task, guide_task)
    }
  end
  let(:combine_gaps_in_care) do
    ->(preferred_task, gaps_in_care_task) {
      preferred_task.bind {
        if gaps_in_care_task.complete?
          compose_tasks.(combine_guide, preferred_task, gaps_in_care_task)
        else
          log.("gaps_in_care_workflow::request_abandoned", "")
          preferred_task
        end
      }
    }
  end
  let(:compose_tasks) do
    ->(combiner, task1, task2) {
      task1.bind { |task1_result|
        task2.fmap { |task2_result|
          combiner.(task1_result, task2_result)
        } 
      }      
    }
  end

  it "bends to my will" do
    manage_pbm_requests = ->(rtpbi_request) {
      preferred_task = Task { pbm_workflow.(rtpbi_request) }
      guide_task = Task { guide_workflow.(pbm_workflow, rtpbi_request) }
      good_rx_task = Task { good_rx_workflow.(rtpbi_request) }
      gaps_in_care_task = Task { gaps_in_care_workflow.(rtpbi_request) }

      Success(rtpbi_request)
        .fmap { |it| log.("manage_pbm_requests::request_received", it) }
        .fmap { |it| log.("manage_pbm_requests::request_sent", it) }
        .bind {
          preferred_task = combine_guide.(preferred_task, guide_task)
          preferred_task = combine_good_rx.(preferred_task, good_rx_task)   
          preferred_task = combine_gaps_in_care.(preferred_task, gaps_in_care_task)
        }
        .value_or { |failure| Failure(failure) }
        .bind { |success| 
          log.("manage_pbm_requests::response_received", success) 
          Success(success)
        }
        .or { |failure|
          log.("manage_pbm_requests::request_failed", failure)
          Failure(failure)
        }
    }

    rtpbi_response_value = manage_pbm_requests.("rtpbi_request::preferred")
      .value_or { |failure| fail(failure) }

    expect(rtpbi_response_value).to eq("rtpbi_response::preferred, rtpbi_response::guide_response::preferred, good_rx::response")
  end
end
