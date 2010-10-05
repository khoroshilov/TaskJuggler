#!/usr/bin/env ruby -w
# encoding: UTF-8
#
# = TextParser.rb -- The TaskJuggler III Project Management Software
#
# Copyright (c) 2006, 2007, 2008, 2009, 2010 by Chris Schlaeger <cs@kde.org>
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of version 2 of the GNU General Public License as
# published by the Free Software Foundation.
#

require 'TextParser/Pattern'
require 'TextParser/Rule'
require 'TextParser/StackElement'
require 'MessageHandler'
require 'TjException'
require 'Log'

class TaskJuggler

  # The TextParser implements a regular LALR parser. But it uses a recursive
  # rule traversor instead of the more commonly found state machine generated by
  # yacc-like tools. Since stack depths is not really an issue with a Ruby
  # implementation this approach has one big advantage. The syntax of the parser
  # can be modified during parsing. This allows support for languages that can
  # extend themself. The TaskJuggler syntax is such an beast. Traditional yacc
  # generated parsers would fail with such a syntax.
  #
  # This class is just a base class. A complete parser would derive from this
  # class and implement the rule set and the functions _nextToken()_ and
  # _returnToken()_. It also needs to set the array _variables_ to declare all
  # variables ($SOMENAME) that the scanner may deliver.
  #
  # To describe the syntax the functions TextParser#pattern, TextParser#optional
  # and TextParser#repeatable can be used. When the rule set is changed during
  # parsing, TextParser#updateParserTables must be called to make the changes
  # effective. The parser can also document the syntax automatically. To
  # document a pattern, the functions TextParser#doc, TextParser#descr,
  # TextParser#also and TextParser#arg can be used.
  #
  # To start parsing the input the function TextParser#parse needs to be called
  # with the name of the start rule.
  class TextParser

    # Utility class so that we can distinguish Array results from the Array
    # containing the results of a repeatable rule.
    class TextParserResultArray < Array

      def initialize
        super
      end

      # If there is a repeatable rule that contains another repeatable loop, the
      # result of the inner rule is an Array that gets put into another Array by
      # the outer rule. In this case, the inner Array can be merged with the
      # outer Array.
      def <<(arg)
        if arg.is_a?(TextParserResultArray)
          self.concat(arg)
        else
          super
        end
      end

    end

    attr_reader :rules, :messageHandler

    # Create a new TextParser object.
    def initialize(messageHandler)
      # The message handler will collect all error messages.
      @messageHandler = messageHandler
      # This Hash will store the ruleset that the parser is operating on.
      @rules = { }
      # Array to hold the token types that the scanner can return.
      @variables = []
      # An list of token types that are not allowed in the current context.
      @badVariables = []
      # The currently processed rule.
      @cr = nil
    end

    # Limit the allowed tokens of the scanner to the subset passed by the
    # _tokenSet_ Array.
    def limitTokenSet(tokenSet)
      return unless tokenSet

      @badVariables = @variables.dup
      @badVariables.delete_if { |v| tokenSet.include?(v) }
    end

    # Call all methods that start with 'rule_' to initialize the rules.
    def initRules
      methods.each do |m|
        if m[0, 5] == 'rule_'
          # Create a new rule with the suffix of the function name as name.
          newRule(m[5..-1])
          # Call the function.
          send(m)
        end
      end
    end

    # Add a new rule to the rule set. _name_ must be a unique identifier. The
    # function also sets the class variable @cr to the new rule. Subsequent
    # calls to TextParser#pattern, TextParser#optional or
    # TextParser#repeatable will then implicitely operate on the most recently
    # added rule.
    def newRule(name)
      # Use a symbol instead of a String.
      name = name.intern
      raise "Fatal Error: Rule #{name} already exists" if @rules.has_key?(name)

      if block_given?
        saveCr = @cr
        @rules[name] = @cr = TextParser::Rule.new(name)
        yield
        @cr = saveCr
      else
        @rules[name] = @cr = TextParser::Rule.new(name)
      end
    end

    # Add a new pattern to the most recently added rule. _tokens_ is an array of
    # strings that specify the syntax elements of the pattern. Each token must
    # start with an character that identifies the type of the token. The
    # following types are supported.
    #
    # * ! a reference to another rule
    # * $ a variable token as delivered by the scanner
    # * _ a literal token.
    #
    # _func_ is a Proc object that is called whenever the parser has completed
    # the processing of this rule.
    def pattern(tokens, func = nil)
      @cr.addPattern(TextParser::Pattern.new(tokens, func))
    end

    # Identify the patterns of the most recently added rule as optional syntax
    # elements.
    def optional
      @cr.setOptional
    end

    # Identify the patterns of the most recently added rule as repeatable syntax
    # elements.
    def repeatable
      @cr.setRepeatable
    end

    # This function needs to be called whenever new rules or patterns have been
    # added and before the next call to TextParser#parse.
    def updateParserTables
      @rules.each_value { |rule| rule.transitions = {} }
      @rules.each_value do |rule|
        getTransitions(rule)
        checkRule(rule)
      end
    end

    # To parse the input this function needs to be called with the name of the
    # rule to start with. It returns the result of the processing function of
    # the top-level parser rule that was specified by _ruleName_. In case of
    # an error, the result is false.
    def parse(ruleName)
      @stack = []
      @@expectedTokens = []
      updateParserTables
      begin
        result = parseRuleR(@rules[ruleName])
      rescue TjException => msg
        if msg.message && !msg.message.empty?
          @messageHandler.critical('parse', msg.message)
        end
        return false
      end

      result
    end

    # Return the SourceFileInfo of the TextScanner at the beginning of the
    # currently processed TextParser::Rule. Or return nil if we don't have a
    # current position.
    def sourceFileInfo
      return nil if @stack.nil? || @stack.empty?
      @stack.last.sourceFileInfo[0]
    end

    def matchingRules(keyword)
      matches = []
      @rules.each do |name, rule|
        patIdx = rule.matchingPatternIndex('_' + keyword)
        matches << [ rule, patIdx ] if patIdx
      end
      matches
    end

    def error(id, text, sfi = nil, data = nil)
      sfi ||= sourceFileInfo
      if @scanner
        # The scanner has some more context information, so we pass the error
        # on to the TextScanner.
        @scanner.error(id, text, sfi, data)
      else
        @messageHandler.error(id, text, sfi, data)
      end
    end

    def warning(id, text, sfi = nil, data = nil)
      sfi ||= sourceFileInfo
      if @scanner
        # The scanner has some more context information, so we pass the
        # warning on to the TextScanner.
        @scanner.warning(id, text, sfi, data)
      else
        @messageHandler.warning(id, text, sfi, data)
      end
    end

  private

    # getTransitions recursively determines all possible target tokens
    # that the _rule_ matches. A target token can either be a fixed token
    # (prefixed with _), a variable token (prefixed with $) or an end token
    # (just a .). The list of found target tokens is stored in the _transitions_
    # list of the rule. For each rule pattern we store the transitions for this
    # pattern in a token -> rule hash.
    def getTransitions(rule)
      # If we have processed this rule before we can just return a copy
      # of the transitions of this rule. This avoids endless recursions.
      return rule.transitions.dup unless rule.transitions.empty?

      rule.transitions = []
      rule.patterns.each do |pat|
        allTokensOptional = true
        transitions = { }
        pat.each do |type, name|
          if type == :reference
            unless @rules.has_key?(name)
              raise "Fatal Error: Unknown reference to '#{name}' in pattern " +
                    "#{pat[0][0]}:#{pat[0][1]} of rule #{rule.name}"
            end
            refRule = @rules[name]
            # If the referenced rule describes optional content, we need to look
            # at the next token as well.
            res = getTransitions(@rules[name])
            allTokensOptional = false unless refRule.optional?(@rules)
            # Combine the hashes for each pattern into a single hash
            res.each do |pat_i|
              pat_i.each { |tok, r| transitions[tok] = r }
            end
          elsif type == :literal || type == :variable
            transitions[[ type, name ]] = rule
            allTokensOptional = false
          elsif type == :eof
          else
            raise 'Fatal Error: Illegal token type specifier used for token' +
                  ": #{type}:#{name}"
          end
          break unless allTokensOptional
        end
        # Make sure that we only have one possible transition for each
        # target.
        transitions.each do |key, value|
          rule.transitions.each do |trans|
            if trans.has_key?(key)
              rule.dump
              raise "Fatal Error: Rule #{rule.name} has ambiguous " +
                    "transitions for target #{key}"
            end
          end
        end
        rule.transitions << transitions
      end
      rule.transitions.dup
    end

    def checkRule(rule)
      if rule.patterns.empty?
        raise "Rule #{rule.name} must have at least one pattern"
      end

      rule.patterns.each do |pat|
        pat.each do |type, name|
          if type == :variable
            if @variables.index(name).nil?
              error('unsupported_token',
                    "The token #{name} is not supported here.")
            end
          elsif type == :reference
            if @rules[name].nil?
              raise "Fatal Error: Reference to unknown rule #{name} in " +
                    "pattern '#{pat}' of rule #{rule.name}"
            end
          end
        end
      end
    end

    # This function processes the input starting with the syntax description of
    # _rule_. It recursively calls this function whenever the syntax description
    # contains the reference to another rule.
    # This recursive version has cleaner code and is about 8% faster than
    # parseRuleNR.
    def parseRuleR(rule)
      #Log.enter('parseRuleR', "Parsing with rule #{rule.name}")
      #puts "Parsing with rule #{rule.name}"
      result = rule.repeatable ? TextParserResultArray.new : nil
      # Rules can be marked 'repeatable'. This flag will be set to true after
      # the first iteration has been completed.
      repeatMode = false
      loop do
        # At the beginning of a rule we need a token from the input to determine
        # which pattern of the rule needs to be processed.
        token = getNextToken

        return result unless (pattern = findPattern(rule, token, repeatMode))
        # The @stack will store the resulting value of each element in the
        # pattern.
        @stack << TextParser::StackElement.new(pattern.function)

        pattern.each do |elType, elName|
          # Separate the type and token text for pattern element.
          if elType == :reference
            # The element is a reference to another rule. Return the token if
            # we still have one and continue with the referenced rule.
            unless token.nil?
              sfi = token[2]
              returnToken(token)
              token = nil
            else
              sfi = nil
            end
            @stack.last.store(parseRuleR(@rules[elName]), sfi)
            #Log << "Resuming rule #{rule.name}"
            #puts "Resuming rule #{rule.name}"
          else
            # In case the element is a keyword or variable we have to get a new
            # token if we don't have one anymore.
            token = getNextToken unless token

            processNormalElements(elType, elName, token)

            # The token has been consumed. Reset the variable.
            token = nil
            @@expectedTokens = []
          end
        end

        # Once the complete pattern has been processed we call the processing
        # function for this pattern to operate on the value array. Then pop the
        # entry for this rule from the stack.
        @val = @stack.last.val
        @sourceFileInfo = @stack.last.sourceFileInfo
        res = nil
        res = @stack.last.function.call unless @stack.last.function.nil?
        @stack.pop

        # If the rule is not repeatable we can store the result and break the
        # outer loop to exit the function.
        unless rule.repeatable
          result = res
          break
        end

        # Otherwise we append the result to the result array and turn repeat
        # mode on.
        result << res
        repeatMode = true
      end

      #Log.exit('parseRuleR', "Finished rule #{rule.name}")
      #puts "Finished rule #{rule.name}"
      return result
    end

    # This function processes the input starting with the syntax description
    # of _rule_. It's implemented as an unrolled recursion.  It recursively
    # iterates over the rule tree as controlled by the input file.
    # This version is not limited by the size of the system stack. So far, I'm
    # not aware of any project that is too large for the system stack. Since
    # the recursive version parseRuleR is about 8% faster and has cleaner
    # code, we use that by default.
    def parseRuleNR(rule)
      elementIdx = 0
      recursionResult = nil
      # These flags are used to managed the control flow to and from the
      # recursion point.
      recur = resume = false
      # The stack that holds the context for the recursion levels. It's either
      # just a rule to start a new recursion or an Array of state variables.
      recursionStack = [ rule ]
      begin
        # Pop the top entry from the recursion stack.
        se = recursionStack.pop
        if se.is_a?(Array)
          # We have essentially finished a recursion level and need to get
          # back to the place where we started the recursion. First, we need
          # to restore the state again.
          rule, pattern, elementIdx, result, repeatMode, sfi = se
          #Log << "Recursion loop started in resume mode for rule #{rule.name}"
          # Now jump to the recursion point without doing anything else.
          resume = true
        else
          # Start a new recursion level. The rule tells us how to interpret
          # the input text.
          rule = se
          #Log.enter('parseRuleNR', "Parsing with rule #{rule.name}")
          resume = false
        end

        unless resume
          result = rule.repeatable ? TextParserResultArray.new : nil
          # Rules can be marked 'repeatable'. This flag will be set to true
          # after the first iteration has been completed.
          repeatMode = false
        end

        loop do
          unless resume
            # At the beginning of a rule we need a token from the input to
            # determine which pattern of the rule needs to be processed.
            token = getNextToken

            break unless (pattern = findPattern(rule, token, repeatMode))
            # The @stack will store the resulting value of each element in the
            # pattern.
            @stack << TextParser::StackElement.new(pattern.function)

            # Once we've found the right pattern, we need to process each
            # element.
            elementIdx = 0
          end

          elementCount = pattern.length
          while elementIdx < elementCount
            elType, elName = pattern[elementIdx]
            if elType == :reference
              unless resume
                # The element is a reference to another rule. Return the token
                # if we still have one and continue with the referenced rule.
                if token
                  sfi = token[2]
                  returnToken(token)
                  token = nil
                else
                  sfi = nil
                end
                # This is where the recursion would happen. Instead, we push
                # the state variables and then the next rule onto the
                # recursion stack.
                recursionStack.push([ rule, pattern, elementIdx, result,
                                      repeatMode, sfi ])
                recursionStack.push(@rules[elName])
                # Now terminate all but the outer loops without doing anything
                # else.
                recur = true
                break
              else
                # We're back right after where the recursion started. Store
                # the result and turn resume mode off again.
                @stack.last.store(recursionResult, sfi)
                resume = false
              end
            else
              # In case the element is a keyword or variable we have to get a
              # new token if we don't have one anymore.
              token = getNextToken unless token

              processNormalElements(elType, elName, token)

              # The token has been consumed. Reset the variable.
              token = nil
              @@expectedTokens = []
            end
            elementIdx += 1
          end # of pattern while loop

          # Skip the rest of the loop in recur mode.
          break if recur

          elementIdx = 0

          # Once the complete pattern has been processed we call the
          # processing function for this pattern to operate on the value
          # array. Then pop the entry for this rule from the stack. The
          # called function will use @val and @sourceFileInfo to retrieve
          # data from the parser.
          @val = @stack.last.val
          @sourceFileInfo = @stack.last.sourceFileInfo
          res = @stack.last.function ? @stack.last.function.call : nil
          @stack.pop

          # If the rule is not repeatable we can store the result and break
          # the outer loop to exit the function.
          unless rule.repeatable
            result = res
            break
          end

          # Otherwise we append the result to the result array and turn repeat
          # mode on.
          result << res
          # We have completed the first iteration. Set the repeat mode flag to
          # indicate that further iterations are already re-runs.
          repeatMode = true
        end # of rule processing loop

        if recur
          recur = false
        else
          #Log.exit('parseRuleNR', "Finished rule #{rule.name}")
          recursionResult = result
        end
      end while !recursionStack.empty?

      return result
    end

    def getNextToken
      token = nextToken
      #Log << "Token: [#{token[0]}][#{token[1]}]"
      if @badVariables.include?(token[0])
        error('unsupported_token',
              "The token #{token[1]} is not supported in this context.",
              token[2])
      end
      token
    end

    def findPattern(rule, token, repeatMode)
      # The scanner cannot differentiate between keywords and identifiers.  So
      # whenever an identifier is returned we have to see if we have a
      # matching keyword first. If none is found, then look for normal
      # identifiers.
      if token[0] == :ID
        if (patIdx = rule.matchingPatternIndex([ :literal, token[1] ])).nil?
          patIdx = rule.matchingPatternIndex([ :variable, :ID ])
        end
      elsif token[0] == :LITERAL
        patIdx = rule.matchingPatternIndex([ :literal, token[1] ])
      elsif token[0] == false
        patIdx = rule.matchingPatternIndex([ :eof, '<END>' ])
      else
        patIdx = rule.matchingPatternIndex([ :variable, token[0] ])
      end

      # If no matching pattern is found for the token we have to check if the
      # rule is optional or we are in repeat mode. If this is the case, return
      # the token back to the scanner. Otherwise, we have found a token we
      # cannot handle at this point.
      if patIdx.nil?
        # Append the list of expected tokens to the @@expectedToken array.
        # This may be used in a later rule to provide more details when an
        # error occured.
        rule.transitions.each do |transition|
          keys = transition.keys
          keys.collect! { |key| "'#{key[1]}'" }
          @@expectedTokens += keys
          @@expectedTokens.sort!
        end

        unless rule.optional?(@rules) || repeatMode
          error('unexpctd_token',
                (token[0] != false ?
                 "Unexpected token '#{token[1]}' of type " +
                 "'#{token[0]}'. " :
                 "Unexpected end of file in #{@scanner.fileName}. ") +
                (@@expectedTokens.length > 1 ?
                 "Expecting one of #{@@expectedTokens.join(', ')}" :
                 "Expecting #{@@expectedTokens[0]}"), token[2])
        end
        returnToken(token)
        return nil
      end

      rule.pattern(patIdx)
    end

    # Handle the elements that don't trigger a recursion.
    def processNormalElements(elType, elToken, token)
      if elType == :literal
        # If the element requires a keyword the token must match this
        # keyword.
        if elToken != token[1]
          text = "'#{elToken}' expected but found " +
                 "'#{token[1]}' (#{token[0]})."
          unless @@expectedTokens.empty?
            text = "#{@@expectedTokens.join(', ')} or " + text
          end
          error('spec_keywork_expctd', text, token[2])
        end
        @stack.last.store(elToken, token[2])
      elsif elType == :eof
        if token[0..1] != [ :eof, '<END>' ]
          error('end_expected',
                "Found garbage at expected end of text: #{token[1]}\n" +
                "If you see this in the middle of your text, you probably " +
                "have closed your context too early.", token[2])
        end
      else
        # The token must match the expected variable type.
        if token[0] != elToken
          text = "'#{elToken}' expected but found " +
                 "'#{token[1]}' (#{token[0]})."
          unless @@expectedTokens.empty?
            text = "#{@@expectedTokens.join(', ')} or " + text
          end
          error('spec_token_expctd', text, token[2])
        end
        # If the element is a variable store the value of the token.
        @stack.last.store(token[1], token[2])
      end
    end

  end

end

