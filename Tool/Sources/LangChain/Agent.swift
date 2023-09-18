import Foundation

public struct AgentAction: Equatable {
    public var toolName: String
    public var toolInput: String
    public var log: String
    public var observation: String?

    public init(toolName: String, toolInput: String, log: String, observation: String? = nil) {
        self.toolName = toolName
        self.toolInput = toolInput
        self.log = log
        self.observation = observation
    }

    public func observationAvailable(_ observation: String) -> AgentAction {
        var newAction = self
        newAction.observation = observation
        return newAction
    }
}

public extension CallbackEvents {
    struct AgentDidFinish<Output: AgentOutputParsable>: CallbackEvent {
        public let info: AgentFinish<Output>
    }

    func agentDidFinish<Output: AgentOutputParsable>() -> AgentDidFinish<Output>.Type {
        AgentDidFinish<Output>.self
    }

    struct AgentActionDidStart: CallbackEvent {
        public let info: AgentAction
    }

    var agentActionDidStart: AgentActionDidStart.Type {
        AgentActionDidStart.self
    }

    struct AgentActionDidEnd: CallbackEvent {
        public let info: AgentAction
    }

    var agentActionDidEnd: AgentActionDidEnd.Type {
        AgentActionDidEnd.self
    }
}

public struct AgentFinish<Output: AgentOutputParsable> {
    public enum ReturnValue {
        case structured(Output)
        case unstructured(String)
    }

    public var returnValue: ReturnValue
    public var log: String

    public init(returnValue: ReturnValue, log: String) {
        self.returnValue = returnValue
        self.log = log
    }
}

public enum AgentNextStep<Output: AgentOutputParsable> {
    case actions([AgentAction])
    case finish(AgentFinish<Output>)
    case thought(String)
}

public struct AgentScratchPad<Content: Equatable>: Equatable {
    var content: Content
}

public struct AgentInput<T, ScratchPadContent: Equatable> {
    var input: T
    var thoughts: AgentScratchPad<ScratchPadContent>

    public init(input: T, thoughts: AgentScratchPad<ScratchPadContent>) {
        self.input = input
        self.thoughts = thoughts
    }
}

extension AgentInput: Equatable where T: Equatable {}

public enum AgentEarlyStopHandleType: Equatable {
    case force
    case generate
}

public protocol Agent {
    associatedtype Input
    associatedtype Output: AgentOutputParsable
    associatedtype ScratchPadContent: Equatable
    var chatModelChain: ChatModelChain<AgentInput<Input, ScratchPadContent>> { get }
    var observationPrefix: String { get }
    var llmPrefix: String { get }

    func validateTools(tools: [AgentTool]) throws
    func constructScratchpad(intermediateSteps: [AgentAction]) -> AgentScratchPad<ScratchPadContent>
    func constructFinalScratchpad(intermediateSteps: [AgentAction]) -> AgentScratchPad<ScratchPadContent>
    func extraPlan(input: AgentInput<Input, ScratchPadContent>)
    func parseOutput(_ output: ChatModelChain<AgentInput<Input, ScratchPadContent>>.Output) async
        -> AgentNextStep<Output>
}

public extension Agent {
    func getFullInputs(
        input: Input,
        intermediateSteps: [AgentAction]
    ) -> AgentInput<Input, ScratchPadContent> {
        let thoughts = constructScratchpad(intermediateSteps: intermediateSteps)
        return AgentInput(input: input, thoughts: thoughts)
    }

    func plan(
        input: Input,
        intermediateSteps: [AgentAction],
        callbackManagers: [CallbackManager]
    ) async throws -> AgentNextStep<Output> {
        let input = getFullInputs(input: input, intermediateSteps: intermediateSteps)
        extraPlan(input: input)
        let output = try await chatModelChain.call(input, callbackManagers: callbackManagers)
        return await parseOutput(output)
    }

    func returnStoppedResponse(
        input: Input,
        earlyStoppedHandleType: AgentEarlyStopHandleType,
        intermediateSteps: [AgentAction],
        callbackManagers: [CallbackManager]
    ) async throws -> AgentFinish<Output> {
        switch earlyStoppedHandleType {
        case .force:
            return AgentFinish(
                returnValue: .unstructured("Agent stopped due to iteration limit or time limit."),
                log: ""
            )
        case .generate:
            let thoughts = constructFinalScratchpad(intermediateSteps: intermediateSteps)
            let input = AgentInput(input: input, thoughts: thoughts)
            let output = try await chatModelChain.call(input, callbackManagers: callbackManagers)
            let nextAction = await parseOutput(output)
            switch nextAction {
            case let .finish(finish):
                return finish
            case .actions:
                return .init(returnValue: .unstructured(output.content ?? ""), log: output.content ?? "")
            case let .thought(content):
                return .init(returnValue: .unstructured(content), log: content)
            }
        }
    }
}
