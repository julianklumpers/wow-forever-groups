local Replies = require("core.replies")

describe("reading a leader's answer", function()
    it("reads a clear refusal", function()
        for _, text in ipairs({ "no", "sorry, full", "nope", "we're full", "no thanks", "already have a dps",
            "nvm found one", "Sorry!", "group is full" }) do
            assert.are.equal("no", Replies.classify(text), text)
        end
    end)

    it("reads a clear yes", function()
        for _, text in ipairs({ "sure", "inv", "yes", "ok sec", "Inviting", "1 min", "no problem", "np",
            "sure, inv coming" }) do
            assert.are.equal("yes", Replies.classify(text), text)
        end
    end)

    it("leaves mixed or unrelated answers open", function()
        for _, text in ipairs({ "sorry, inviting now", "what class?", "lvl?", "", "no problem but full" }) do
            assert.is_nil(Replies.classify(text), text)
        end
        assert.is_nil(Replies.classify(nil))
    end)

    it("does not read a group's missing role or a question as a refusal or a yes", function()
        assert.are.equal("yes", Replies.classify("no probs"))
        assert.are.equal("yes", Replies.classify("no problemo"))
        assert.are.equal("yes", Replies.classify("1 min"))
        for _, text in ipairs({ "not full yet", "we have no tank, can you tank?", "no tank yet",
            "what is your min ilvl", "1k" }) do
            assert.is_nil(Replies.classify(text), text)
        end
    end)

    it("does not read words inside other words", function()
        assert.is_nil(Replies.classify("know any healer?"))
        assert.is_nil(Replies.classify("fullmetal"))
    end)
end)
