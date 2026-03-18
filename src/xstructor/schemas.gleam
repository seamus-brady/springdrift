//// XSD schemas and XML examples for all XStructor call sites.
////
//// Each schema defines the contract between the LLM and the application.
//// The XML examples serve as few-shot prompts showing the expected format.

// ---------------------------------------------------------------------------
// 1. Candidates (dprime/deliberative.gleam) — simplest
// ---------------------------------------------------------------------------

pub const candidates_xsd = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<xs:schema xmlns:xs=\"http://www.w3.org/2001/XMLSchema\">
  <xs:element name=\"candidates\">
    <xs:complexType>
      <xs:sequence>
        <xs:element name=\"candidate\" maxOccurs=\"unbounded\">
          <xs:complexType>
            <xs:sequence>
              <xs:element name=\"description\" type=\"xs:string\"/>
              <xs:element name=\"projected_outcome\" type=\"xs:string\" minOccurs=\"0\"/>
            </xs:sequence>
          </xs:complexType>
        </xs:element>
      </xs:sequence>
    </xs:complexType>
  </xs:element>
</xs:schema>"

pub const candidates_example = "<candidates>
  <candidate>
    <description>Approach A: directly answer the question using available context</description>
    <projected_outcome>User gets a quick, factual answer</projected_outcome>
  </candidate>
  <candidate>
    <description>Approach B: search for additional information first</description>
    <projected_outcome>More thorough but slower response</projected_outcome>
  </candidate>
</candidates>"

// ---------------------------------------------------------------------------
// 2. Forecasts (dprime/scorer.gleam)
// ---------------------------------------------------------------------------

pub const forecasts_xsd = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<xs:schema xmlns:xs=\"http://www.w3.org/2001/XMLSchema\">
  <xs:element name=\"forecasts\">
    <xs:complexType>
      <xs:sequence>
        <xs:element name=\"forecast\" maxOccurs=\"unbounded\">
          <xs:complexType>
            <xs:sequence>
              <xs:element name=\"feature\" type=\"xs:string\"/>
              <xs:element name=\"magnitude\">
                <xs:simpleType>
                  <xs:restriction base=\"xs:integer\">
                    <xs:minInclusive value=\"0\"/>
                    <xs:maxInclusive value=\"3\"/>
                  </xs:restriction>
                </xs:simpleType>
              </xs:element>
              <xs:element name=\"rationale\" type=\"xs:string\" minOccurs=\"0\"/>
            </xs:sequence>
          </xs:complexType>
        </xs:element>
      </xs:sequence>
    </xs:complexType>
  </xs:element>
</xs:schema>"

pub const forecasts_example = "<forecasts>
  <forecast>
    <feature>user_safety</feature>
    <magnitude>0</magnitude>
    <rationale>No safety concern with this request</rationale>
  </forecast>
  <forecast>
    <feature>accuracy</feature>
    <magnitude>1</magnitude>
    <rationale>Minor concern about data freshness</rationale>
  </forecast>
</forecasts>"

// ---------------------------------------------------------------------------
// 3. Summary (narrative/summary.gleam)
// ---------------------------------------------------------------------------

pub const summary_xsd = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<xs:schema xmlns:xs=\"http://www.w3.org/2001/XMLSchema\">
  <xs:element name=\"summary_response\">
    <xs:complexType>
      <xs:sequence>
        <xs:element name=\"summary\" type=\"xs:string\"/>
        <xs:element name=\"keywords\" minOccurs=\"0\">
          <xs:complexType>
            <xs:sequence>
              <xs:element name=\"keyword\" type=\"xs:string\" minOccurs=\"0\" maxOccurs=\"unbounded\"/>
            </xs:sequence>
          </xs:complexType>
        </xs:element>
      </xs:sequence>
    </xs:complexType>
  </xs:element>
</xs:schema>"

pub const summary_example = "<summary_response>
  <summary>Over the past week I handled 15 research cycles covering market analysis and weather monitoring. I identified a recurring pattern in API reliability issues and adapted my tool selection accordingly.</summary>
  <keywords>
    <keyword>market analysis</keyword>
    <keyword>weather monitoring</keyword>
    <keyword>API reliability</keyword>
  </keywords>
</summary_response>"

// ---------------------------------------------------------------------------
// 4. CBR Case (narrative/archivist.gleam — CBR generation)
// ---------------------------------------------------------------------------

pub const cbr_case_xsd = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<xs:schema xmlns:xs=\"http://www.w3.org/2001/XMLSchema\">
  <xs:element name=\"cbr_case\">
    <xs:complexType>
      <xs:sequence>
        <xs:element name=\"problem\">
          <xs:complexType>
            <xs:sequence>
              <xs:element name=\"user_input\" type=\"xs:string\"/>
              <xs:element name=\"intent\" type=\"xs:string\" minOccurs=\"0\"/>
              <xs:element name=\"domain\" type=\"xs:string\" minOccurs=\"0\"/>
              <xs:element name=\"entities\" minOccurs=\"0\">
                <xs:complexType>
                  <xs:sequence>
                    <xs:element name=\"entity\" type=\"xs:string\" minOccurs=\"0\" maxOccurs=\"unbounded\"/>
                  </xs:sequence>
                </xs:complexType>
              </xs:element>
              <xs:element name=\"keywords\" minOccurs=\"0\">
                <xs:complexType>
                  <xs:sequence>
                    <xs:element name=\"keyword\" type=\"xs:string\" minOccurs=\"0\" maxOccurs=\"unbounded\"/>
                  </xs:sequence>
                </xs:complexType>
              </xs:element>
              <xs:element name=\"query_complexity\" type=\"xs:string\" minOccurs=\"0\"/>
            </xs:sequence>
          </xs:complexType>
        </xs:element>
        <xs:element name=\"solution\">
          <xs:complexType>
            <xs:sequence>
              <xs:element name=\"approach\" type=\"xs:string\"/>
              <xs:element name=\"agents_used\" minOccurs=\"0\">
                <xs:complexType>
                  <xs:sequence>
                    <xs:element name=\"agent\" type=\"xs:string\" minOccurs=\"0\" maxOccurs=\"unbounded\"/>
                  </xs:sequence>
                </xs:complexType>
              </xs:element>
              <xs:element name=\"tools_used\" minOccurs=\"0\">
                <xs:complexType>
                  <xs:sequence>
                    <xs:element name=\"tool\" type=\"xs:string\" minOccurs=\"0\" maxOccurs=\"unbounded\"/>
                  </xs:sequence>
                </xs:complexType>
              </xs:element>
              <xs:element name=\"steps\" minOccurs=\"0\">
                <xs:complexType>
                  <xs:sequence>
                    <xs:element name=\"step\" type=\"xs:string\" minOccurs=\"0\" maxOccurs=\"unbounded\"/>
                  </xs:sequence>
                </xs:complexType>
              </xs:element>
            </xs:sequence>
          </xs:complexType>
        </xs:element>
        <xs:element name=\"outcome\">
          <xs:complexType>
            <xs:sequence>
              <xs:element name=\"status\" type=\"xs:string\"/>
              <xs:element name=\"confidence\" type=\"xs:decimal\" minOccurs=\"0\"/>
              <xs:element name=\"assessment\" type=\"xs:string\" minOccurs=\"0\"/>
              <xs:element name=\"pitfalls\" minOccurs=\"0\">
                <xs:complexType>
                  <xs:sequence>
                    <xs:element name=\"pitfall\" type=\"xs:string\" minOccurs=\"0\" maxOccurs=\"unbounded\"/>
                  </xs:sequence>
                </xs:complexType>
              </xs:element>
            </xs:sequence>
          </xs:complexType>
        </xs:element>
      </xs:sequence>
    </xs:complexType>
  </xs:element>
</xs:schema>"

pub const cbr_case_example = "<cbr_case>
  <problem>
    <user_input>What is the current weather in London?</user_input>
    <intent>data_query</intent>
    <domain>environment</domain>
    <entities>
      <entity>London</entity>
    </entities>
    <keywords>
      <keyword>weather</keyword>
      <keyword>London</keyword>
      <keyword>current</keyword>
    </keywords>
    <query_complexity>simple</query_complexity>
  </problem>
  <solution>
    <approach>Delegated to researcher agent for web search and extraction</approach>
    <agents_used>
      <agent>researcher</agent>
    </agents_used>
    <tools_used>
      <tool>web_search</tool>
      <tool>fetch_url</tool>
    </tools_used>
    <steps>
      <step>Searched DuckDuckGo for current London weather</step>
      <step>Extracted temperature and conditions from weather site</step>
    </steps>
  </solution>
  <outcome>
    <status>success</status>
    <confidence>0.9</confidence>
    <assessment>Successfully retrieved current weather data</assessment>
    <pitfalls>
      <pitfall>Weather data may be cached and slightly stale</pitfall>
    </pitfalls>
  </outcome>
</cbr_case>"

// ---------------------------------------------------------------------------
// 5. NarrativeEntry (narrative/archivist.gleam — narrative generation)
// ---------------------------------------------------------------------------

pub const narrative_entry_xsd = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<xs:schema xmlns:xs=\"http://www.w3.org/2001/XMLSchema\">
  <xs:element name=\"narrative_entry\">
    <xs:complexType>
      <xs:sequence>
        <xs:element name=\"summary\" type=\"xs:string\"/>
        <xs:element name=\"intent\" minOccurs=\"0\">
          <xs:complexType>
            <xs:sequence>
              <xs:element name=\"classification\" type=\"xs:string\" minOccurs=\"0\"/>
              <xs:element name=\"description\" type=\"xs:string\" minOccurs=\"0\"/>
              <xs:element name=\"domain\" type=\"xs:string\" minOccurs=\"0\"/>
            </xs:sequence>
          </xs:complexType>
        </xs:element>
        <xs:element name=\"outcome\" minOccurs=\"0\">
          <xs:complexType>
            <xs:sequence>
              <xs:element name=\"status\" type=\"xs:string\" minOccurs=\"0\"/>
              <xs:element name=\"confidence\" type=\"xs:decimal\" minOccurs=\"0\"/>
              <xs:element name=\"assessment\" type=\"xs:string\" minOccurs=\"0\"/>
            </xs:sequence>
          </xs:complexType>
        </xs:element>
        <xs:element name=\"delegation_chain\" minOccurs=\"0\">
          <xs:complexType>
            <xs:sequence>
              <xs:element name=\"step\" minOccurs=\"0\" maxOccurs=\"unbounded\">
                <xs:complexType>
                  <xs:sequence>
                    <xs:element name=\"agent\" type=\"xs:string\" minOccurs=\"0\"/>
                    <xs:element name=\"instruction\" type=\"xs:string\" minOccurs=\"0\"/>
                    <xs:element name=\"outcome\" type=\"xs:string\" minOccurs=\"0\"/>
                    <xs:element name=\"contribution\" type=\"xs:string\" minOccurs=\"0\"/>
                  </xs:sequence>
                </xs:complexType>
              </xs:element>
            </xs:sequence>
          </xs:complexType>
        </xs:element>
        <xs:element name=\"decisions\" minOccurs=\"0\">
          <xs:complexType>
            <xs:sequence>
              <xs:element name=\"decision\" minOccurs=\"0\" maxOccurs=\"unbounded\">
                <xs:complexType>
                  <xs:sequence>
                    <xs:element name=\"point\" type=\"xs:string\" minOccurs=\"0\"/>
                    <xs:element name=\"choice\" type=\"xs:string\" minOccurs=\"0\"/>
                    <xs:element name=\"rationale\" type=\"xs:string\" minOccurs=\"0\"/>
                  </xs:sequence>
                </xs:complexType>
              </xs:element>
            </xs:sequence>
          </xs:complexType>
        </xs:element>
        <xs:element name=\"keywords\" minOccurs=\"0\">
          <xs:complexType>
            <xs:sequence>
              <xs:element name=\"keyword\" type=\"xs:string\" minOccurs=\"0\" maxOccurs=\"unbounded\"/>
            </xs:sequence>
          </xs:complexType>
        </xs:element>
        <xs:element name=\"entities\" minOccurs=\"0\">
          <xs:complexType>
            <xs:sequence>
              <xs:element name=\"locations\" minOccurs=\"0\">
                <xs:complexType>
                  <xs:sequence>
                    <xs:element name=\"location\" type=\"xs:string\" minOccurs=\"0\" maxOccurs=\"unbounded\"/>
                  </xs:sequence>
                </xs:complexType>
              </xs:element>
              <xs:element name=\"organisations\" minOccurs=\"0\">
                <xs:complexType>
                  <xs:sequence>
                    <xs:element name=\"organisation\" type=\"xs:string\" minOccurs=\"0\" maxOccurs=\"unbounded\"/>
                  </xs:sequence>
                </xs:complexType>
              </xs:element>
              <xs:element name=\"data_points\" minOccurs=\"0\">
                <xs:complexType>
                  <xs:sequence>
                    <xs:element name=\"data_point\" minOccurs=\"0\" maxOccurs=\"unbounded\">
                      <xs:complexType>
                        <xs:sequence>
                          <xs:element name=\"label\" type=\"xs:string\" minOccurs=\"0\"/>
                          <xs:element name=\"value\" type=\"xs:string\" minOccurs=\"0\"/>
                          <xs:element name=\"unit\" type=\"xs:string\" minOccurs=\"0\"/>
                          <xs:element name=\"period\" type=\"xs:string\" minOccurs=\"0\"/>
                          <xs:element name=\"source\" type=\"xs:string\" minOccurs=\"0\"/>
                        </xs:sequence>
                      </xs:complexType>
                    </xs:element>
                  </xs:sequence>
                </xs:complexType>
              </xs:element>
              <xs:element name=\"temporal_references\" minOccurs=\"0\">
                <xs:complexType>
                  <xs:sequence>
                    <xs:element name=\"reference\" type=\"xs:string\" minOccurs=\"0\" maxOccurs=\"unbounded\"/>
                  </xs:sequence>
                </xs:complexType>
              </xs:element>
            </xs:sequence>
          </xs:complexType>
        </xs:element>
        <xs:element name=\"sources\" minOccurs=\"0\">
          <xs:complexType>
            <xs:sequence>
              <xs:element name=\"source\" minOccurs=\"0\" maxOccurs=\"unbounded\">
                <xs:complexType>
                  <xs:sequence>
                    <xs:element name=\"type\" type=\"xs:string\" minOccurs=\"0\"/>
                    <xs:element name=\"name\" type=\"xs:string\" minOccurs=\"0\"/>
                  </xs:sequence>
                </xs:complexType>
              </xs:element>
            </xs:sequence>
          </xs:complexType>
        </xs:element>
        <xs:element name=\"metrics\" minOccurs=\"0\">
          <xs:complexType>
            <xs:sequence>
              <xs:element name=\"total_duration_ms\" type=\"xs:integer\" minOccurs=\"0\"/>
              <xs:element name=\"input_tokens\" type=\"xs:integer\" minOccurs=\"0\"/>
              <xs:element name=\"output_tokens\" type=\"xs:integer\" minOccurs=\"0\"/>
              <xs:element name=\"thinking_tokens\" type=\"xs:integer\" minOccurs=\"0\"/>
              <xs:element name=\"tool_calls\" type=\"xs:integer\" minOccurs=\"0\"/>
              <xs:element name=\"agent_delegations\" type=\"xs:integer\" minOccurs=\"0\"/>
              <xs:element name=\"dprime_evaluations\" type=\"xs:integer\" minOccurs=\"0\"/>
              <xs:element name=\"model_used\" type=\"xs:string\" minOccurs=\"0\"/>
            </xs:sequence>
          </xs:complexType>
        </xs:element>
        <xs:element name=\"observations\" minOccurs=\"0\">
          <xs:complexType>
            <xs:sequence>
              <xs:element name=\"observation\" minOccurs=\"0\" maxOccurs=\"unbounded\">
                <xs:complexType>
                  <xs:sequence>
                    <xs:element name=\"type\" type=\"xs:string\" minOccurs=\"0\"/>
                    <xs:element name=\"severity\" type=\"xs:string\" minOccurs=\"0\"/>
                    <xs:element name=\"detail\" type=\"xs:string\" minOccurs=\"0\"/>
                  </xs:sequence>
                </xs:complexType>
              </xs:element>
            </xs:sequence>
          </xs:complexType>
        </xs:element>
      </xs:sequence>
    </xs:complexType>
  </xs:element>
</xs:schema>"

pub const narrative_entry_example = "<narrative_entry>
  <summary>I was asked about the current weather in London. I delegated to the researcher agent who performed a web search and extracted the relevant data.</summary>
  <intent>
    <classification>data_query</classification>
    <description>User requested current weather information</description>
    <domain>environment</domain>
  </intent>
  <outcome>
    <status>success</status>
    <confidence>0.9</confidence>
    <assessment>Successfully retrieved and presented weather data</assessment>
  </outcome>
  <delegation_chain>
    <step>
      <agent>researcher</agent>
      <instruction>Search for current London weather</instruction>
      <outcome>success</outcome>
      <contribution>Found temperature 12C, partly cloudy</contribution>
    </step>
  </delegation_chain>
  <keywords>
    <keyword>weather</keyword>
    <keyword>London</keyword>
  </keywords>
  <entities>
    <locations>
      <location>London</location>
    </locations>
  </entities>
  <metrics>
    <input_tokens>500</input_tokens>
    <output_tokens>200</output_tokens>
    <tool_calls>2</tool_calls>
    <agent_delegations>1</agent_delegations>
    <model_used>claude-haiku-4-5-20251001</model_used>
  </metrics>
</narrative_entry>"

// ---------------------------------------------------------------------------
// System prompt fragments
// ---------------------------------------------------------------------------

/// Build an XStructor system prompt from a base prompt, schema, and example.
pub fn build_system_prompt(
  base_prompt: String,
  xsd_schema: String,
  xml_example: String,
) -> String {
  base_prompt
  <> "\n\nRespond with ONLY valid XML matching this schema. No preamble, no markdown fences, no explanation.\n\nXML SCHEMA (XSD):\n"
  <> xsd_schema
  <> "\n\nEXAMPLE OUTPUT:\n"
  <> xml_example
}
