require "spec_helper"
require "app/features/build_runner/remote_runner"

describe FastlaneCI::RemoteRunner do
  describe "emits events" do
    xit "subscribe to events"
    xit "completion blocks get called if a subscriber joins after the runner completes"
    xit "unsubscribe from events"
  end

  xit "topic name is scoped to the project id and build number"

  describe "handling grpc responses" do
    it "handles log events" do
      expect(subscriber).to receive(log)
    end

    it "handles state events" do
      expect(subscriber).to receive(state)
      expect(build).to be_saved
    end

    it "handles error events" do
      expect(subscriber).to receive(error)
    end

    it "handles artifact events" do
    end
  end
end
