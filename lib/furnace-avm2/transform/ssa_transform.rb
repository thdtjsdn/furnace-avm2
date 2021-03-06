require 'pp'

module Furnace::AVM2
  module Transform
    class SSAMetadata
      attr_reader :sets, :gets
      attr_reader :set_map, :gets_map, :gets_upper
      attr_accessor :live

      def initialize(hash={})
        @hash = hash.freeze
        @sets, @gets, @live = Set[], Set[], Set[]
        @set_map     = {}
        @gets_map    = Hash.new { |h, k| h[k] = Set[] }
        @gets_upper  = {}
      end

      def [](key)
        @hash[key]
      end

      def any?
        @sets.any? || @gets.any? || @live.any?
      end

      def to_hash
        {
          sets: @sets.to_a,
          gets: @gets.to_a,
          live: @live.to_a,
        }.merge(@hash)
      end

      def inspect
        str  = "| sets: #{@sets.to_a.join(", ")} gets: #{@gets.to_a.join(", ")}\n"
        str << "| live: #{@live.to_a.join(", ")}"
        #str << "\n| set_map: #{@set_map.pretty_inspect}"
        #str << "| gets_map: #{@gets_map.pretty_inspect}"
        #str << "| gets_upper: #{@gets_upper.pretty_inspect}"
        str
      end

      def merge!(other)
        @sets.merge other.sets
        @gets.merge other.gets
        @live.merge other.live

        @set_map.merge!(other.set_map)
        @gets_map.merge!(other.gets_map) { |key, ours, theirs| ours + theirs }
        @gets_upper.merge!(other.gets_upper)
      end

      def add_get(ids, upper, node)
        @gets.merge ids
        ids.each do |id|
          @gets_map[id].add node
        end
        @gets_upper[node] = upper
      end

      def add_set(id, node)
        @sets.add id
        @set_map[id] = node
        @live.add id
      end

      def remove_get(id)
        @gets.delete id
        @gets_map[id].each do |node|
          node.children.delete id
          if node.children.empty?
            @gets_upper.delete node
          end
        end
        @gets_map.delete id
      end

      def unregister_get(id)
        @gets.delete id
        @gets_map[id].each do |node|
          @gets_upper.delete node
        end
        @gets_map.delete id
      end

      def remove_set(id)
        @sets.delete id
        @set_map.delete id
        @live.delete id
      end
    end

    class SSATransform
      include SubgraphOperations

      class ASTNormalizer
        include Furnace::AST::StrictVisitor

        # (if-* a b) -> (branch-if (*' a b))
        BINARY_IF_MAPPING = {
          :eq        => [true,  :==],
          :ne        => [true,  :!=],
          :ge        => [true,  :>=],
          :nge       => [false, :>=],
          :gt        => [true,  :>],
          :ngt       => [false, :>],
          :le        => [true,  :<=],
          :nle       => [false, :<=],
          :lt        => [true,  :<],
          :nlt       => [false, :<],
          :strict_eq => [true,  :===],
          :strict_ne => [false, :===], # Why? Because of (lookup-switch ...).
        }

        BINARY_IF_MAPPING.each do |cond, (positive, comp)|
          define_method :"on_if_#{cond}" do |node|
            node.update(:branch_if, [
              positive,
              AST::Node.new(comp, node.children)
            ])
          end
        end

        [true, false].each do |cond|
          define_method :"on_if_#{cond}" do |node|
            node.update(:branch_if, [
              cond,
              node.children.first
            ])
          end
        end
      end

      def transform(cfg)
        @cfg     = cfg
        @stacks  = {}

        @next_rid = 0
        @rids     = Hash.new { [] }

        @next_rlabel = 0

        normalizer = ASTNormalizer.new

        worklist = ssa_worklist(cfg)
        visited  = Set[]

        while worklist.any?
          block = worklist.shift

          if visited.include?(block)
            raise "already visited block #{block.label}"
          end

          visited.add block

          block.metadata = SSAMetadata.new(block.metadata)

          if block == cfg.entry
            stack = []
          elsif block.metadata[:exception]
            @stacks[block] = [
              block.label # :"exc_N"
            ]

            next
          else
            base_stack = block.sources.map { |s| @stacks[s] }.find { |x| x }
            if base_stack.nil?
              raise "block without base stack"
            end

            parent_stacks = block.sources.map { |s| get_stack(s, base_stack) }
            if block != cfg.exit && parent_stacks.map(&:size).uniq.count != 1
              raise "nonmatching stacks at #{block.label} " <<
                    "(from #{block.sources.map(&:label).join(", ")})"
            end

            block.metadata.live.merge parent_stacks.flatten

            first, *others = parent_stacks
            stack = first.zip(*others).map { |list| list.flatten.uniq }
          end

          nodes = []

          block.insns.each do |opcode|
            case opcode
            when ABC::AS3Dup
              check_stack! stack, 1
              stack.push stack.last

            when ABC::AS3Swap
              check_stack! stack, 2
              a, b = stack.pop, stack.pop
              stack.push a, b

            when ABC::AS3Pop
              check_stack! stack, 1
              stack.pop

            else
              node = AST::Node.new(opcode.ast_type, [], opcode.metadata)

              if opcode.produces == 1
                stack_id = get_rid(block)
                toplevel_node = s(stack_id, node)
              else
                toplevel_node = node
              end

              parameters = consume(stack, opcode.consumes,
                    toplevel_node, block.metadata)
              if opcode.consumes_context
                context = opcode.context(consume(stack, opcode.consumes_context,
                      toplevel_node, block.metadata))
              end

              node.children.concat context if context
              node.children.concat opcode.parameters
              node.children.concat parameters

              normalizer.visit node

              nodes.push(toplevel_node)

              if opcode.produces == 1
                produce(stack, stack_id,
                      toplevel_node, block.metadata)
              end

              if block.cti == opcode
                block.cti = node
              end
            end
          end

          block.insns = nodes

          @stacks[block] = stack
        end

        @cfg.exit.metadata.live.clear

        @cfg
      end

      private

      def get_rid(block)
        if @rids[block].any?
          @rids[block].shift
        else
          @next_rid += 1
        end
      end

      def get_stack(block, base_stack)
        if @stacks[block]
          @stacks[block]
        else
          if @rids[block].empty?
            @rids[block] = base_stack.size.times.map { get_rid(block) }
          end

          @rids[block].map { |rid| [rid] }
        end
      end

      def r(ids)
        @next_rlabel += 1
        AST::Node.new(:r, ids) # , { label: @next_rlabel })
      end

      def s(id, wat)
        metadata = {}
        [ :read_barrier, :write_barrier ].each do |key|
          if value = wat.metadata.delete(key)
            metadata[key] = value
          end
        end

        AST::Node.new(:s, [ id.to_i, wat.to_astlet ],
              metadata)
      end

      def check_stack!(stack, count)
        if count > stack.size
          raise "cannot consume #{count}: stack underflow with #{stack.size}"
        end
      end

      def consume(stack, count, node, metadata)
        check_stack! stack, count

        if count == 0
          []
        else
          stack.slice!(-count..-1).map do |ids|
            get_node = r(ids)

            metadata.add_get(ids, node, get_node)

            get_node
          end
        end
      end

      def produce(stack, id, node, metadata)
        metadata.add_set id, node

        stack.push [id]
      end
    end
  end
end