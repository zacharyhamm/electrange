/// Pure weighted choices made when a walking or running animation completes.
nonisolated enum IdleBehaviorPolicy {
    struct Input: Equatable {
        var currentAnimationName: String
        var proposedNextAnimationID: String?
    }

    static func evaluate(_ input: Input, random: (Int) -> Int) -> String? {
        var nextID = input.proposedNextAnimationID
        if input.currentAnimationName == "walk", nextID == AnimationID.walk.rawValue {
            let roll = random(100)
            if roll <= BehaviorConstants.pissChance {
                nextID = AnimationID.piss.rawValue
            } else if roll <= BehaviorConstants.pissChance + BehaviorConstants.eatChance {
                nextID = AnimationID.eat.rawValue
            } else if roll <= BehaviorConstants.pissChance
                        + BehaviorConstants.eatChance
                        + BehaviorConstants.runChance {
                nextID = AnimationID.runBegin.rawValue
            }
        } else if input.currentAnimationName == "run",
                  random(100) <= BehaviorConstants.jumpWhileRunningChance {
            nextID = AnimationID.jump.rawValue
        }
        return nextID
    }
}
