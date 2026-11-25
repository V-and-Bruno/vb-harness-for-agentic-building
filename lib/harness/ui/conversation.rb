# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require "securerandom"
require_relative "../errors"
require_relative "../figma/designs"
require_relative "../model/http"
require_relative "../model/probe"
require_relative "../model/stream"
require_relative "../model/tokens"
require_relative "../prompts"
require_relative "../untrusted"
require_relative "chat_tools"

module Harness
  module UI
    # Chat mode (DESIGN.md 11.3): the conversation goes to the chosen model and streams back. It is fitted to the
    # context with the budget rules of section 7: the newest messages are kept, and the oldest become a summary.
    class Conversation
      SUMMARY_TOKENS = 600
      LIST_TIMEOUT = 3
      # Room kept for one picture when fitting a chat to the context. Servers count pictures differently; this is a
      # safe middle, and only decides how many old messages are kept.
      IMAGE_TOKENS = 1500
      MAX_IMAGES = 3
      # All pictures of one message, as sent (the request limit is HTTP::MAX_BODY). The page shrinks them first.
      MAX_IMAGE_CHARS = 900_000
      # A picture as the page sends it, and what its first bytes must be.
      IMAGE = %r{\Adata:image/(png|jpeg|webp);base64,([A-Za-z0-9+/]+={0,2})\z}
      MAGIC = { "png" => "\x89PNG\r\n\x1A\n".b, "jpeg" => "\xFF\xD8\xFF".b, "webp" => "RIFF".b }.freeze
      # Of the context, the part kept free for what the tools return, and characters per token when counting it.
      TOOL_SHARE = 0.35
      CHARS_PER_TOKEN = 3
      UNSEEN = "[A picture was attached here, but this model cannot see pictures.]"

      # @param raw [Object] the pictures of a message, as the page sent them
      # @return [Array<String>] the same data URLs, checked
      # @raise [ParseError]
      def self.images(raw)
        return [] if raw.nil?
        raise ParseError, "up to #{MAX_IMAGES} pictures" unless raw.is_a?(Array) && raw.size <= MAX_IMAGES && raw.all?(String)
        raise ParseError, "the pictures are too large" if raw.sum(&:bytesize) > MAX_IMAGE_CHARS

        raw.each do |url|
          m = IMAGE.match(url) or raise ParseError, "a picture must be a PNG, JPEG or WebP"
          raise ParseError, "a picture must be a PNG, JPEG or WebP" unless m[2].unpack1("m").start_with?(MAGIC.fetch(m[1]))
        end
      end
      RETRY_NOTICE = "The model ran out of room while thinking; asking again with thinking off."

      # @param config [Config]
      # @param chats [Chats]
      # @param probe [Model::Probe]
      # @param stream [Model::Stream]
      # @param http [Model::Http]
      # @param env [Hash{String=>String}]
      # @param tools [#call, nil] (project name, room) -> ChatTools, for a project the user picked; nil: no reading
      # @param clock [#call] monotonic seconds, for how long the model thought
      def initialize(config:, chats:, probe:, stream:, http:, env:, tools: nil, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
        @config = config
        @chats = chats
        @probe = probe
        @stream = stream
        @http = http
        @env = env
        @tools = tools
        @clock = clock
        @jobs = {}
        @mutex = Mutex.new
      end

      # Every model of every configured profile, as "profile · model id".
      # @return [Array<Hash>] profile, model, label, and error when the server could not be asked
      def models
        @config.profiles.values.flat_map do |p|
          res = @http.get("#{p.base_url}/models", headers: Model::Probe.headers(p, @env), timeout: LIST_TIMEOUT)
          ids = res.ok? && res.json.is_a?(Hash) ? Array(res.json["data"]).filter_map { |m| m["id"] if m.is_a?(Hash) } : []
          ids = [p.model] if ids.empty?
          ids.map { |id| { "profile" => p.name, "model" => id, "label" => "#{p.name} · #{id}" } }
        rescue ModelUnavailableError => e
          [{ "profile" => p.name, "model" => p.model, "label" => "#{p.name} · #{p.model}", "error" => e.message }]
        end
      end

      # What the chosen model can do, for the page: measured by the probe, never assumed (I1).
      # @param choice [Hash, nil] {"profile", "model"}
      # @return [Hash] {"images" => Boolean, "tools" => Boolean}
      def abilities(choice)
        caps = capabilities({ "model" => choice })
        { "images" => caps&.images == "native", "tools" => caps&.tool_calls == "native" }
      end

      # @param chat [Hash]
      # @return [Boolean] whether the chosen model can call tools
      def uses_tools?(chat) = capabilities(chat)&.tool_calls == "native"

      # @param chat [Hash]
      # @return [Boolean] false too when the server cannot be asked
      def sees_images?(chat) = capabilities(chat)&.images == "native"

      # The design a message links to, read once and saved with it.
      # @param text [String] the user's message
      # @return [Hash] {"design" => fenced text}, {"designError" => why it could not be read}, or {} without a link
      def design(text)
        found = Figma::Designs.new(env: @env, token_env: @config.figma_token_env, http: @http).outline(text)
        found ? { "design" => found } : {}
      rescue ConfigError => e
        { "designError" => e.message }
      end

      # Register a reply to stream; it starts when the browser opens the stream.
      # @param chat_id [String]
      # @return [String] the stream id
      def prepare(chat_id)
        id = SecureRandom.hex(8)
        @mutex.synchronize { @jobs[id] = { chat: chat_id, stop: false } }
        id
      end

      # @param id [String]
      # @return [Boolean] whether there was such a stream
      def stop(id)
        @mutex.synchronize do
          job = @jobs[id]
          job[:stop] = true if job
          !job.nil?
        end
      end

      # Generate the reply into the SSE stream, then save it to the chat.
      # @param id [String] from prepare
      # @param sse [SSE]
      # @return [void]
      def run(id, sse)
        job = @mutex.synchronize { @jobs[id] }
        return sse.event("error", { "error" => "no such stream" }) unless job

        chat = @chats.get(job[:chat])
        profile, model = choice(chat)
        text = +""
        thinking = +""
        timer = ThinkingTimer.new(@clock)
        last = chat["messages"].reverse.find { |m| m["role"] == "user" } || {}
        sse.event("notice", { "text" => last["designError"] }) if last["designError"]
        tools = reading(chat, last, profile)
        messages = fit(chat, profile, tools ? last["reads"] : nil)
        calls = []
        reply = lambda do |off|
          calls.clear
          @stream.call(profile: profile, model: model, messages: messages, max_tokens: profile.max_output_tokens, calls: calls,
                       tools: tools&.definitions, tool_choice: tools && !tools.more? ? "none" : nil,
                       thinking_off: off, stop: -> { job[:stop] || sse.closed? }) do |piece|
            (piece.kind == "text" ? text : thinking) << piece.text
            timer.piece(piece.kind)
            sse.event(piece.kind, { "text" => piece.text })
          end
        end
        off = nil
        retried = false
        finish = nil
        loop do
          said = text.size
          finish = reply.call(off)
          control = out_of_room?(finish, text[said..]) && calls.empty? && !retried ? @probe.call(profile).thinking_control : "none"
          if control != "none"
            # Like the model client: a reply that spent its whole allowance thinking is asked again once, thinking off.
            retried = true
            off = control
            sse.event("notice", { "text" => RETRY_NOTICE })
            finish = reply.call(off)
          end
          break if tools.nil? || calls.empty? || finish == "stopped" || !tools.more?

          look_up(tools, calls, text[said..], messages, sse)
          sse.event("text", { "text" => "\n\n" }) && text << "\n\n" if text.size > said && !text.end_with?("\n\n")
        end
        if out_of_room?(finish, text)
          return sse.event("error", { "error" => "The model used its whole output allowance (#{profile.max_output_tokens} tokens) " \
                                                 "on thinking and gave no answer#{retried ? ', even with thinking off' : ''}. Raise " \
                                                 "maxOutputTokens for this profile, or ask a narrower question." })
        end

        thought = thinking.empty? ? nil : timer.ms
        @chats.append(chat["id"], { "role" => "assistant", "content" => text, "thinking" => thinking.empty? ? nil : thinking,
                                    "thinkingMs" => thought, "model" => "#{profile.name} · #{model}", "finish" => finish,
                                    "retried" => retried || nil, "read" => tools && tools.steps.map(&:to_json_hash) }.compact)
        sse.event("done", { "finish" => finish, "thinkingMs" => thought }.compact)
      rescue ModelUnavailableError, ConfigError => e
        sse.event("error", { "error" => e.message })
      ensure
        @mutex.synchronize { @jobs.delete(id) }
      end

      # How long a reply thought: from its first thinking piece to its first answer piece (or its last thinking piece
      # when no answer came). Shown as "Thought for 12s" above the reply.
      class ThinkingTimer
        # @param clock [#call] monotonic seconds
        def initialize(clock)
          @clock = clock
          @from = nil
          @to = nil
          @answered = false
        end

        # @param kind [String] "thinking" or "text"
        # @return [void]
        def piece(kind)
          return if @answered

          now = @clock.call
          if kind == "thinking"
            @from ||= now
            @to = now
          elsif @from
            @to = now
            @answered = true
          end
        end

        # @return [Integer, nil] milliseconds, nil when the reply did not think
        def ms = @from && ((@to - @from) * 1000).round
      end

      private

      # @return [Model::Probe::Result, nil] nil when the server cannot be asked
      def capabilities(chat)
        profile, model = choice(chat)
        @probe.call(profile.with(model: model))
      rescue ModelUnavailableError
        nil
      end

      # @return [ChatTools, nil] when the user picked a project for this message and the model can call tools
      # @raise [ConfigError] when the project is gone or cannot be read
      def reading(chat, message, profile)
        return nil unless @tools && message["reads"] && uses_tools?(chat)

        @tools.call(message["reads"], (@probe.call(profile).context_tokens * TOOL_SHARE * CHARS_PER_TOKEN).to_i)
      rescue GitError => e
        raise ConfigError, "#{message['reads']} could not be read: #{e.message}"
      end

      # Run the calls a reply made, and add them and their results to the conversation.
      # @return [void]
      def look_up(tools, calls, said, messages, sse)
        ids = calls.each_with_index.map { |c, i| c["id"].empty? ? "call_#{messages.size}_#{i}" : c["id"] }
        messages << { "role" => "assistant", "content" => said.to_s, "tool_calls" => calls.each_with_index.map { |c, i|
          { "id" => ids[i], "type" => "function", "function" => { "name" => c["name"], "arguments" => c["arguments"].empty? ? "{}" : c["arguments"] } }
        } }
        calls.each_with_index do |c, i|
          result = tools.call(c["name"], c["arguments"])
          sse.event("read", tools.steps.last.to_json_hash)
          messages << { "role" => "tool", "tool_call_id" => ids[i], "content" => result }
        end
      end

      # @return [Boolean] the reply ended at the output limit with no answer text
      def out_of_room?(finish, text)
        finish == "length" && text.strip.empty?
      end

      # @return [Array(Model::Profile, String)]
      def choice(chat)
        want = chat["model"].is_a?(Hash) ? chat["model"] : {}
        profile = @config.profiles[want["profile"]] || @config.profile_for(:implementer)
        [profile, want["model"].is_a?(String) && !want["model"].empty? ? want["model"] : profile.model]
      end

      # The newest messages that fit, after a summary of the older ones.
      # @return [Array<Hash>]
      def fit(chat, profile, reads = nil)
        system = Prompts.render("chat_system")
        system = "#{system}\n\n#{Prompts.render('chat_tools', project: reads, calls: ChatTools::MAX_CALLS)}" if reads
        context = @probe.call(profile).context_tokens
        budget = context - profile.max_output_tokens - Model::Tokens.estimate(system) - SUMMARY_TOKENS
        budget -= (context * TOOL_SHARE).to_i if reads
        turns = chat["messages"].each_with_index.select { |m, _| %w[user assistant].include?(m["role"]) }
        kept = []
        used = 0
        turns.reverse_each do |m, i|
          cost = Model::Tokens.estimate("#{m['content']}#{m['design']}") + Model::Tokens::MESSAGE_OVERHEAD + (Array(m["images"]).size * IMAGE_TOKENS)
          break if used + cost > budget && !kept.empty?

          kept.unshift([m, i])
          used += cost
        end
        older = turns.take(turns.size - kept.size)
        out = [{ "role" => "system", "content" => system }]
        out << { "role" => "system", "content" => "Summary of the earlier conversation:\n#{summary(chat, older, profile)}" } unless older.empty?
        sees = kept.any? { |m, _| m["images"] } && sees_images?(chat)
        out + kept.map { |m, _| { "role" => m["role"], "content" => content(m, sees) } }
      end

      # @param message [Hash]
      # @param sees [Boolean] whether the model sees pictures (a chat may have switched to one that does not)
      # @return [String, Array<Hash>] text, or text and pictures
      def content(message, sees)
        text = [message["content"].to_s, message["design"], message["designError"] && "[The design the user linked to could not be read: #{message['designError']}]"].compact.join("\n\n")
        images = Array(message["images"])
        return text if images.empty?
        return "#{text}\n\n#{UNSEEN}".strip unless sees

        parts = images.map { |url| { "type" => "image_url", "image_url" => { "url" => url } } }
        text.strip.empty? ? parts : [{ "type" => "text", "text" => text }, *parts]
      end

      # @return [String] cached in the chat until more messages fall out of the window
      def summary(chat, older, profile)
        upto = older.last[1]
        cached = chat["summary"]
        return cached["text"] if cached.is_a?(Hash) && cached["upTo"] == upto

        transcript = older.map { |m, _| "#{m['role']}: #{m['content']}" }.join("\n\n")
        prompt = [{ "role" => "system", "content" => Prompts.render("chat_summary") },
                  { "role" => "user", "content" => Untrusted.fence(transcript[-(SUMMARY_TOKENS * 20)..] || transcript) }]
        text = +""
        @stream.call(profile: profile, model: choice(chat)[1], messages: prompt, max_tokens: SUMMARY_TOKENS) do |piece|
          text << piece.text if piece.kind == "text"
        end
        @chats.update(chat["id"]) { |c| c["summary"] = { "upTo" => upto, "text" => text.strip } }
        text.strip
      end
    end
  end
end
