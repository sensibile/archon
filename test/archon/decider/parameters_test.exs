# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Ported from conductor-oss core/src/test/java/com/netflix/conductor/core/utils/ParametersUtilsTest.java
# and core/src/test/java/com/netflix/conductor/core/execution/TestDeciderService.java
# (getTaskInput cases) at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: rewritten as ExUnit tests; cases for the environment/secrets providers,
# schema version 1, JsonUtils.expand and thread safety were dropped or adapted as noted.

defmodule Archon.Decider.ParametersTest do
  use ExUnit.Case, async: true

  alias Archon.Decider.Parameters
  alias Archon.Domain.{Task, TaskDef, Workflow, WorkflowDef}

  defp expressions(value) do
    value |> Parameters.find_expressions() |> Enum.map_join(fn {s, e} -> "[#{s}-#{e}]" end)
  end

  # TestDeciderService#createDefaultWorkflow
  defp default_workflow do
    names = [%{"name" => "The Who", "year" => 1970}, %{"name" => "The Doors", "year" => 1975}]

    %Workflow{
      workflow_definition: %WorkflowDef{name: "TestDeciderService", version: 1},
      input: %{"requestId" => "request id 001", "hasAwards" => true, "channelMapping" => 5},
      output: %{"name" => hd(names), "names" => names, "awards" => 200},
      tasks: [
        %Task{
          reference_task_name: "task2",
          output_data: %{"location" => "http://location"},
          status: :completed
        },
        %Task{
          reference_task_name: "task3",
          output_data: %{"refId" => "abcddef_1234_7890_aaffcc"},
          status: :scheduled
        }
      ]
    }
  end

  @external_id ~s({"taskRefName":"t001","workflowId":"w002"})

  describe "ParametersUtilsTest" do
    test "testReplace" do
      doc = %{"name" => "conductor", "version" => 2, "externalId" => @external_id}
      input = %{"k1" => "${$.externalId}", "k4" => "${name}", "k5" => "${version}"}

      assert Parameters.replace(input, doc) == %{
               "k1" => @external_id,
               "k4" => "conductor",
               "k5" => 2
             }
    end

    # The document is given already expanded, as JsonUtils.expand would leave it. `$..` (deep
    # scan) is not supported (ADR 0014) and the upstream test does not assert it.
    test "testReplaceWithArrayExpand" do
      doc = [
        %{
          "externalId" => [%{"taskRefName" => "t001", "workflowId" => "w002"}],
          "name" => "conductor",
          "version" => 2
        }
      ]

      input = %{
        "k1" => "${$..externalId}",
        "k2" => "${$[0].externalId[0].taskRefName}",
        "k3" => "${__json_externalId.taskRefName}",
        "k4" => "${$[0].name}",
        "k5" => "${$[0].version}"
      }

      replaced = Parameters.replace(input, doc)
      assert replaced["k2"] == "t001"
      assert replaced["k3"] == nil
      assert replaced["k4"] == "conductor"
      assert replaced["k5"] == 2
    end

    test "testReplaceWithMapExpand" do
      doc = %{
        "externalId" => %{"taskRefName" => "t001", "workflowId" => "w002"},
        "name" => "conductor",
        "version" => 2
      }

      input = %{
        "k1" => "${$.externalId}",
        "k2" => "${externalId.taskRefName}",
        "k4" => "${name}",
        "k5" => "${version}"
      }

      replaced = Parameters.replace(input, doc)
      assert replaced["k2"] == "t001"
      assert replaced["k3"] == nil
      assert replaced["k4"] == "conductor"
      assert replaced["k5"] == 2
    end

    test "testReplaceInputWithMapAndList" do
      doc = %{"name" => "conductor", "version" => 2, "externalId" => @external_id}

      input = %{
        "k1" => "${$.externalId}",
        "k2" => "${name}",
        "k3" => "${version}",
        "k4" => "${}",
        "k5" => "${    }",
        "map" => %{"name" => "${name}", "version" => "${version}"},
        "list" => ["${name}", "${version}"]
      }

      assert Parameters.replace(input, doc) == %{
               "k1" => @external_id,
               "k2" => "conductor",
               "k3" => 2,
               "k4" => "",
               "k5" => "",
               "map" => %{"name" => "conductor", "version" => 2},
               "list" => ["conductor", 2]
             }
    end

    test "testNestedPathExpressions" do
      doc = %{
        "name" => "conductor",
        "index" => 1,
        "mapValue" => "a",
        "recordIds" => [1, 2, 3],
        "map" => %{"a" => [1, 2, 3], "b" => [2, 4, 5], "c" => [3, 7, 8]}
      }

      input = %{
        "k1" => "${recordIds[${index}]}",
        "k2" => "${map.${mapValue}[${index}]}",
        "k3" => "${map.b[${map.${mapValue}[${index}]}]}"
      }

      assert Parameters.replace(input, doc) == %{"k1" => 2, "k2" => 2, "k3" => 5}
    end

    test "testReplaceWithLineTerminators" do
      doc = %{"name" => "conductor", "version" => 2}

      input = %{
        "k1" => "Name: ${name}; Version: ${version};",
        "k2" => "Name: ${name};\nVersion: ${version};",
        "k3" => "Name: ${name};\rVersion: ${version};",
        "k4" => "Name: ${name};\r\nVersion: ${version};"
      }

      assert Parameters.replace(input, doc) == %{
               "k1" => "Name: conductor; Version: 2;",
               "k2" => "Name: conductor;\nVersion: 2;",
               "k3" => "Name: conductor;\rVersion: 2;",
               "k4" => "Name: conductor;\r\nVersion: 2;"
             }
    end

    test "testReplaceWithEscapedTags" do
      doc = %{"someString" => "conductor", "someNumber" => 2}

      input = %{
        "k1" => "${$.someString} $${$.someNumber}${$.someNumber} ${$.someNumber}$${$.someString}",
        "k2" => "$${$.someString}afterText",
        "k3" => "beforeText$${$.someString}",
        "k4" => "$${$.someString} afterText",
        "k5" => "beforeText $${$.someString}",
        "map" => %{
          "a" => "${someString}",
          "b" => "${someNumber}",
          "c" => "$${someString} ${someNumber}"
        },
        "list" => ["${someString}", "${someNumber}", "${someString} $${someNumber}"]
      }

      assert Parameters.replace(input, doc) == %{
               "k1" => "conductor ${$.someNumber}2 2${$.someString}",
               "k2" => "${$.someString}afterText",
               "k3" => "beforeText${$.someString}",
               "k4" => "${$.someString} afterText",
               "k5" => "beforeText ${$.someString}",
               "map" => %{"a" => "conductor", "b" => 2, "c" => "${someString} 2"},
               "list" => ["conductor", 2, "conductor ${someNumber}"]
             }
    end

    test "getWorkflowInputHandlesNullInputTemplate" do
      assert Parameters.workflow_input(%WorkflowDef{}, %{"key" => "value"}) == %{
               "key" => "value"
             }

      assert Parameters.workflow_input(%WorkflowDef{input_template: nil}, %{"key" => "value"}) ==
               %{"key" => "value"}
    end

    test "getWorkflowInputFillsInTemplatedFields" do
      definition = %WorkflowDef{input_template: %{"other_key" => "other_value"}}

      assert Parameters.workflow_input(definition, %{"key" => "value"}) == %{
               "key" => "value",
               "other_key" => "other_value"
             }
    end

    test "getWorkflowInputPreservesExistingFieldsIfPopulated" do
      definition = %WorkflowDef{input_template: %{"key" => "templated_value"}}

      assert Parameters.workflow_input(definition, %{"key" => "supplied_value"}) == %{
               "key" => "supplied_value"
             }
    end

    # Without an environment provider (Archon has none), workflow.env.* falls through to the
    # JsonPath read and is null.
    test "testWorkflowEnvResolvesEagerly, without an environment provider" do
      workflow = %Workflow{workflow_definition: %WorkflowDef{}}
      input = %{"region" => "${workflow.env.REGION}"}

      assert Parameters.task_input(input, workflow, "t1", nil) == %{"region" => nil}
    end

    test "testWorkflowSecretsLeftLiteralDuringNormalResolution" do
      workflow = %Workflow{workflow_definition: %WorkflowDef{}}
      input = %{"pwd" => "${workflow.secrets.DB_PASSWORD}"}

      assert Parameters.task_input(input, workflow, "t1", nil) == %{
               "pwd" => "${workflow.secrets.DB_PASSWORD}"
             }
    end

    test "testFindExpressions" do
      assert expressions("no expressions here") == ""
      assert expressions("${a}") == "[0-4]"
      assert expressions("x ${a} y ${b} z") == "[2-6][9-13]"
      assert expressions("${a.${b}}") == "[0-9]"
      assert expressions("${a{b{c}d}e}") == "[0-12]"
      assert expressions("${}") == "[0-3]"
      assert expressions("$${a}") == ""
      assert expressions("$${a} ${b}") == "[6-10]"
      assert expressions("{}} ${a} {") == "[4-8]"
      assert expressions("${a") == ""
      assert expressions("${a} ${b ${c}") == "[0-4]"
      assert expressions("$") == ""
      assert expressions("") == ""
    end

    # Run under PCRE, the legacy pattern also matches expressions after a `${` that is never
    # closed; under Java's engine (upstream's test) and in testFindExpressions above, an
    # unclosed expression hides everything after it. PCRE matches past that point are dropped.
    test "testFindExpressionsMatchesLegacyPattern" do
      # The regular expression findExpressions replaced upstream, kept as the reference.
      legacy =
        ~r/(?=(?<!\$)\$\{)(?:(?=.*?\{(?!.*?\1)(.*\}(?!.*\2).*))(?=.*?\}(?!.*?\2)(.*)).)+?.*?(?=\1)[^{]*(?=\2$)/s

      alphabet = ["$", "{", "}", "a", "\n"]

      for length <- 0..6, input <- words(alphabet, length) do
        expected =
          legacy
          |> Regex.scan(input, return: :index, capture: :first)
          |> Enum.map(fn [{start, len}] -> {start, start + len} end)
          |> Enum.reduce_while({[], 0}, fn {start, stop}, {kept, from} ->
            if unclosed_start?(input, from, start),
              do: {:halt, {kept, from}},
              else: {:cont, {[{start, stop} | kept], stop}}
          end)
          |> elem(0)
          |> Enum.reverse()
          |> Enum.map_join(fn {start, stop} -> "[#{start}-#{stop}]" end)

        assert expressions(input) == expected, "Input: #{inspect(input)}"
      end
    end

    test "testReplaceIsNotVulnerableToReDoS" do
      depth = 1_000

      input = %{
        "nested" => String.duplicate("${", depth) <> "name" <> String.duplicate("}", depth),
        "unclosed" => "${" <> String.duplicate("{", 100_000),
        "many" => String.duplicate("${name} ", 50_000),
        "closingOnly" => String.duplicate("}", 100_000) <> "${name}"
      }

      {micros, replaced} =
        :timer.tc(fn -> Parameters.replace(input, %{"name" => "conductor"}) end)

      assert micros < 10_000_000
      assert replaced["unclosed"] == input["unclosed"]
      assert replaced["many"] == String.duplicate("conductor ", 50_000)
      assert replaced["closingOnly"] == String.duplicate("}", 100_000) <> "conductor"
      assert Map.has_key?(replaced, "nested")
      assert replaced["nested"] == nil
    end

    test "testReplaceNestingDepthBoundary" do
      doc =
        Map.new(1..31, fn i -> {"k#{i}", if(i == 31, do: "resolvedValue", else: "k#{i + 1}")} end)

      nested = fn depth ->
        String.duplicate("${", depth) <> "k1" <> String.duplicate("}", depth)
      end

      assert Parameters.replace(%{"test31" => nested.(31)}, doc) == %{
               "test31" => "resolvedValue"
             }

      assert Parameters.replace(%{"test32" => nested.(32)}, doc) == %{"test32" => nil}
    end

    test "testReplaceDeepNestingDoesNotThrowStackOverflowOrOOM" do
      depth = 100_000
      nested = String.duplicate("${", depth) <> "name" <> String.duplicate("}", depth)

      assert Parameters.replace(%{"nested" => nested}, %{"name" => "conductor"}) == %{
               "nested" => nil
             }
    end
  end

  describe "TestDeciderService" do
    test "testGetTaskInputV2" do
      workflow = default_workflow()

      input = %{
        "workflowInputParam" => "${workflow.input.requestId}",
        "taskOutputParam" => "${task2.output.location}",
        "taskOutputParam2" => "${task2.output.locationBad}",
        "taskOutputParam3" => "${task3.output.location}",
        "constParam" => "Some String value",
        "nullValue" => nil,
        "task2Status" => "${task2.status}",
        "channelMap" => "${workflow.input.channelMapping}"
      }

      assert Parameters.task_input(input, workflow, nil, nil) == %{
               "workflowInputParam" => "request id 001",
               "taskOutputParam" => "http://location",
               "taskOutputParam2" => nil,
               "taskOutputParam3" => nil,
               "constParam" => "Some String value",
               "nullValue" => nil,
               "task2Status" => "COMPLETED",
               "channelMap" => 5
             }
    end

    # Upstream sets the JVM property EC2_INSTANCE; Archon exposes no server environment
    # (ADR 0014), so the reference reads as it would on a server without that variable.
    test "testGetTaskInputV2Partial" do
      workflow = default_workflow()

      input = %{
        "workflowInputParam" => "${workflow.input.requestId}",
        "workfowOutputParam" => "${workflow.output.name}",
        "taskOutputParam" => "${task2.output.location}",
        "taskOutputParam2" => "${task2.output.locationBad}",
        "taskOutputParam3" => "${task3.output.location}",
        "constParam" => "Some String value   &",
        "partial" => "${task2.output.location}/something?host=${EC2_INSTANCE}",
        "jsonPathExtracted" => "${workflow.output.names[*].year}",
        "secondName" => "${workflow.output.names[1].name}",
        "concatenatedName" => "The Band is: ${workflow.output.names[1].name}-\t${EC2_INSTANCE}"
      }

      task_def = %TaskDef{
        input_template: %{
          "opname" => "${workflow.output.name}",
          "listValues" => [
            ["${workflow.input.requestId}-10-${EC2_INSTANCE}"],
            %{
              "name" => "${workflow.output.names[0].name}",
              "hasAwards" => "${workflow.input.hasAwards}"
            }
          ]
        }
      }

      task_input = Parameters.task_input(input, workflow, nil, task_def)

      assert task_input["workflowInputParam"] == "request id 001"
      assert task_input["workfowOutputParam"] == %{"name" => "The Who", "year" => 1970}
      assert task_input["taskOutputParam"] == "http://location"
      assert Map.has_key?(task_input, "taskOutputParam2")
      assert task_input["taskOutputParam2"] == nil
      assert task_input["taskOutputParam3"] == nil
      assert task_input["jsonPathExtracted"] == [1970, 1975]
      assert task_input["secondName"] == "The Doors"
      assert task_input["concatenatedName"] == "The Band is: The Doors-\tnull"
      assert task_input["partial"] == "http://location/something?host=null"
      assert task_input["opname"] == %{"name" => "The Who", "year" => 1970}

      assert task_input["listValues"] == [
               ["request id 001-10-null"],
               %{"name" => "The Who", "hasAwards" => true}
             ]
    end

    test "testGetTaskInput" do
      input = %{
        "workflowInputParam" => "${workflow.input.requestId}",
        "taskOutputParam" => "${task2.output.location}",
        "complexJson" => [
          %{
            "name" => "person name",
            "city" => "New York",
            "phone" => 2_120_001_234,
            "status" => "${task2.output.isPersonActive}"
          },
          %{
            "employer" => "City Of New York",
            "color" => "purple",
            "requestId" => "${workflow.input.requestId}"
          }
        ]
      }

      workflow = %Workflow{
        workflow_definition: %WorkflowDef{name: "testGetTaskInput"},
        input: %{"requestId" => "request id 001"},
        tasks: [
          %Task{
            reference_task_name: "task2",
            output_data: %{"location" => "http://location", "isPersonActive" => true}
          }
        ]
      }

      task_input = Parameters.task_input(input, workflow, nil, nil)

      assert task_input["workflowInputParam"] == "request id 001"
      assert task_input["taskOutputParam"] == "http://location"

      assert task_input["complexJson"] == [
               %{
                 "name" => "person name",
                 "city" => "New York",
                 "phone" => 2_120_001_234,
                 "status" => true
               },
               %{
                 "employer" => "City Of New York",
                 "color" => "purple",
                 "requestId" => "request id 001"
               }
             ]
    end

    test "testGetTaskInputV2WithInputTemplate" do
      task_def = %TaskDef{
        input_template: %{
          "url" => "https://some_url:7004",
          "default_url" => "https://default_url:7004",
          "someKey" => "someValue"
        }
      }

      workflow = %Workflow{
        workflow_definition: %WorkflowDef{name: "testGetTaskInputV2WithInputTemplate", version: 1},
        input: %{
          "some_new_url" => "https://some_new_url:7004",
          "workflow_input_url" => "https://workflow_input_url:7004",
          "some_other_key" => "some_other_value"
        }
      }

      input = %{
        "url" => "${workflow.input.some_new_url}",
        "workflow_input_url" => "${workflow.input.workflow_input_url}",
        "someKey" => "${workflow.input.someKey}",
        "someOtherKey" => "${workflow.input.some_other_key}",
        "someNowhereToBeFoundKey" => "${workflow.input.some_ne_key}"
      }

      assert Parameters.task_input(input, workflow, nil, task_def) == %{
               "url" => "https://some_new_url:7004",
               "default_url" => "https://default_url:7004",
               "workflow_input_url" => "https://workflow_input_url:7004",
               "someOtherKey" => "some_other_value",
               "someKey" => "someValue",
               "someNowhereToBeFoundKey" => nil
             }
    end

    # testConcurrentTaskInputCalc, without threads: the values are immutable in Elixir.
    test "testConcurrentTaskInputCalc" do
      task_def = %TaskDef{
        input_template: %{
          "input" => [
            %{
              "path" => "${workflow.input.inputLocation}",
              "type" => "${workflow.input.sourceType}",
              "channelMapping" => "${workflow.input.channelMapping}"
            }
          ]
        }
      }

      for x <- 0..9 do
        workflow = %Workflow{
          workflow_definition: %WorkflowDef{name: "testConcurrentTaskInputCalc", version: 1},
          input: %{
            "outputLocation" => "baggins://outputlocation/#{x}",
            "inputLocation" => "baggins://inputlocation/#{x}",
            "sourceType" => "MuxedSource",
            "channelMapping" => x
          }
        }

        assert [%{"channelMapping" => ^x}] =
                 Parameters.task_input(%{}, workflow, nil, task_def)["input"]
      end
    end

    # testTaskRetry: ${CPEWF_TASK_ID} is the ID of the task being scheduled.
    test "CPEWF_TASK_ID resolves to the task ID" do
      input = %{"task_id" => "${CPEWF_TASK_ID}", "env" => %{"env_task_id" => "${CPEWF_TASK_ID}"}}

      assert Parameters.task_input(input, default_workflow(), "t1", nil) == %{
               "task_id" => "t1",
               "env" => %{"env_task_id" => "t1"}
             }
    end
  end

  describe "beyond the upstream tests" do
    test "a malformed path resolves to nil instead of raising" do
      input = %{"v" => "${a['\\uZZZZ']}", "u" => "${a['\\u-001']}", "w" => "x${a[}"}

      assert Parameters.replace(input, %{"a" => 1}) == %{
               "v" => nil,
               "u" => nil,
               "w" => "xnull"
             }
    end

    test "the workflow entry carries the workflow's own fields" do
      workflow = %Workflow{
        default_workflow()
        | workflow_id: "w1",
          status: :running,
          correlation_id: "c1",
          variables: %{"v" => 1}
      }

      input = %{
        "id" => "${workflow.workflowId}",
        "type" => "${workflow.workflowType}",
        "version" => "${workflow.version}",
        "status" => "${workflow.status}",
        "schema" => "${workflow.schemaVersion}",
        "correlation" => "${workflow.correlationId}",
        "variable" => "${workflow.variables.v}"
      }

      assert Parameters.task_input(input, workflow, nil, nil) == %{
               "id" => "w1",
               "type" => "TestDeciderService",
               "version" => 1,
               "status" => "RUNNING",
               "schema" => 2,
               "correlation" => "c1",
               "variable" => 1
             }
    end

    test "loop tasks are keyed without their iteration and the last task wins" do
      workflow = %Workflow{
        workflow_definition: %WorkflowDef{name: "loop"},
        tasks: [
          %Task{reference_task_name: "body__1", iteration: 1, output_data: %{"n" => 1}},
          %Task{reference_task_name: "body__2", iteration: 2, output_data: %{"n" => 2}},
          %Task{reference_task_name: "retried", task_id: "a", output_data: %{"n" => 1}},
          %Task{reference_task_name: "retried", task_id: "b", output_data: %{"n" => 2}}
        ]
      }

      input = %{"body" => "${body.output.n}", "retried" => "${retried.taskId}"}

      assert Parameters.task_input(input, workflow, nil, nil) == %{"body" => 2, "retried" => "b"}
    end

    test "taskDefName falls back to the task type" do
      workflow = %Workflow{
        workflow_definition: %WorkflowDef{name: "wf"},
        tasks: [%Task{reference_task_name: "t", task_type: "SIMPLE", task_def_name: ""}]
      }

      assert Parameters.task_input(%{"n" => "${t.taskDefName}"}, workflow, nil, nil) == %{
               "n" => "SIMPLE"
             }
    end

    test "NETFLIX_ENV, NETFLIX_STACK and an unset task ID stay as written" do
      input = %{
        "env" => "${NETFLIX_ENV}",
        "stack" => "x-${NETFLIX_STACK}",
        "task" => "${CPEWF_TASK_ID}",
        "home" => "${HOME}"
      }

      assert Parameters.task_input(input, default_workflow(), nil, nil) == %{
               "env" => "${NETFLIX_ENV}",
               "stack" => "x-${NETFLIX_STACK}",
               "task" => "${CPEWF_TASK_ID}",
               "home" => nil
             }
    end

    test "values rendered into text use Java's toString" do
      doc = %{
        "f1" => 1.5,
        "f2" => 100.0,
        "f3" => 1.0e7,
        "f4" => 1.0e-4,
        "f5" => 0.001,
        "f6" => 12_345_678.9,
        "f7" => -2.5,
        "f8" => 123_456.0,
        "f9" => 0.0,
        "f10" => -0.0,
        "b" => false,
        "n" => nil,
        "l" => [1, "a", nil],
        "m" => %{"b" => 2, "a" => [1]}
      }

      input =
        Map.new(Map.keys(doc), fn key -> {key, "<${#{key}}>"} end)

      assert Parameters.replace(input, doc) == %{
               "f1" => "<1.5>",
               "f2" => "<100.0>",
               "f3" => "<1.0E7>",
               "f4" => "<1.0E-4>",
               "f5" => "<0.001>",
               "f6" => "<1.23456789E7>",
               "f7" => "<-2.5>",
               "f8" => "<123456.0>",
               "f9" => "<0.0>",
               "f10" => "<-0.0>",
               "b" => "<false>",
               "n" => "<null>",
               "l" => "<[1, a, null]>",
               "m" => "<{a=[1], b=2}>"
             }
    end

    test "inputTemplate fills keys that are missing or nil before resolution" do
      task_def = %TaskDef{input_template: %{"a" => "${workflow.input.x}", "b" => "kept"}}
      workflow = %Workflow{workflow_definition: %WorkflowDef{}, input: %{"x" => 1}}

      assert Parameters.task_input(%{"a" => nil, "b" => "given"}, workflow, nil, task_def) == %{
               "a" => 1,
               "b" => "given"
             }

      assert Parameters.task_input(nil, workflow, nil, nil) == %{}
    end
  end

  # An unescaped `${` in [from, to) whose braces never balance.
  defp unclosed_start?(input, from, to) do
    Enum.any?(from..(to - 1)//1, fn position ->
      binary_part(input, position, min(2, byte_size(input) - position)) == "${" and
        (position == 0 or :binary.at(input, position - 1) != ?$) and
        not balanced?(binary_part(input, position + 1, byte_size(input) - position - 1), 0)
    end)
  end

  defp balanced?(<<?{, rest::binary>>, depth), do: balanced?(rest, depth + 1)
  defp balanced?(<<?}, _rest::binary>>, 1), do: true
  defp balanced?(<<?}, rest::binary>>, depth), do: balanced?(rest, depth - 1)
  defp balanced?(<<_char, rest::binary>>, depth), do: balanced?(rest, depth)
  defp balanced?(<<>>, _depth), do: false

  defp words(_alphabet, 0), do: [""]

  defp words(alphabet, length) do
    for prefix <- words(alphabet, length - 1), char <- alphabet, do: prefix <> char
  end
end
