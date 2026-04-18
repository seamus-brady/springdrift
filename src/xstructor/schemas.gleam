//// XSD schemas and XML examples for all XStructor call sites.
////
//// Each schema defines the contract between the LLM and the application.
//// The XML examples serve as few-shot prompts showing the expected format.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

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
        <xs:element name=\"strategy_used\" type=\"xs:string\" minOccurs=\"0\"/>
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
  <strategy_used>delegate-then-synthesise</strategy_used>
</narrative_entry>"

// ---------------------------------------------------------------------------
// 6. Planner output (agent/framework.gleam)
// ---------------------------------------------------------------------------

pub const planner_output_xsd = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<xs:schema xmlns:xs=\"http://www.w3.org/2001/XMLSchema\">
  <xs:element name=\"plan\">
    <xs:complexType>
      <xs:sequence>
        <xs:element name=\"title\" type=\"xs:string\"/>
        <xs:element name=\"complexity\" type=\"xs:string\"/>
        <xs:element name=\"steps\">
          <xs:complexType>
            <xs:sequence>
              <xs:element name=\"step\" type=\"xs:string\" maxOccurs=\"unbounded\"/>
            </xs:sequence>
          </xs:complexType>
        </xs:element>
        <xs:element name=\"dependencies\" minOccurs=\"0\">
          <xs:complexType>
            <xs:sequence>
              <xs:element name=\"dep\" minOccurs=\"0\" maxOccurs=\"unbounded\">
                <xs:complexType>
                  <xs:attribute name=\"from\" type=\"xs:string\" use=\"required\"/>
                  <xs:attribute name=\"to\" type=\"xs:string\" use=\"required\"/>
                </xs:complexType>
              </xs:element>
            </xs:sequence>
          </xs:complexType>
        </xs:element>
        <xs:element name=\"risks\" minOccurs=\"0\">
          <xs:complexType>
            <xs:sequence>
              <xs:element name=\"risk\" type=\"xs:string\" minOccurs=\"0\" maxOccurs=\"unbounded\"/>
            </xs:sequence>
          </xs:complexType>
        </xs:element>
        <xs:element name=\"verifications\" minOccurs=\"0\">
          <xs:complexType>
            <xs:sequence>
              <xs:element name=\"verify\" type=\"xs:string\" minOccurs=\"0\" maxOccurs=\"unbounded\"/>
            </xs:sequence>
          </xs:complexType>
        </xs:element>
        <xs:element name=\"forecaster_config\" minOccurs=\"0\">
          <xs:complexType>
            <xs:sequence>
              <xs:element name=\"threshold\" type=\"xs:string\" minOccurs=\"0\"/>
              <xs:element name=\"feature\" minOccurs=\"0\" maxOccurs=\"unbounded\">
                <xs:complexType>
                  <xs:attribute name=\"name\" type=\"xs:string\" use=\"required\"/>
                  <xs:attribute name=\"importance\" type=\"xs:string\" use=\"required\"/>
                </xs:complexType>
              </xs:element>
            </xs:sequence>
          </xs:complexType>
        </xs:element>
      </xs:sequence>
    </xs:complexType>
  </xs:element>
</xs:schema>"

pub const planner_output_example = "<plan>
  <title>Research competitor pricing</title>
  <complexity>medium</complexity>
  <steps>
    <step>Search for competitor websites</step>
    <step>Extract pricing data from each site</step>
    <step>Compare pricing tiers and features</step>
    <step>Summarise findings in a table</step>
  </steps>
  <dependencies>
    <dep from=\"1\" to=\"2\"/>
    <dep from=\"2\" to=\"3\"/>
  </dependencies>
  <risks>
    <risk>Pricing pages may require login</risk>
    <risk>Some competitors may not publish pricing</risk>
  </risks>
  <verifications>
    <verify>At least 3 competitor URLs found</verify>
    <verify>Pricing data extracted for each competitor</verify>
    <verify>Comparison table has tier breakdown</verify>
    <verify>Summary includes year-on-year trends</verify>
  </verifications>
  <forecaster_config>
    <threshold>0.60</threshold>
    <feature name=\"scope_creep\" importance=\"high\"/>
  </forecaster_config>
</plan>"

// ---------------------------------------------------------------------------
// Pre-mortem schema — predicted failure modes before work begins
// ---------------------------------------------------------------------------

pub const pre_mortem_xsd = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<xs:schema xmlns:xs=\"http://www.w3.org/2001/XMLSchema\">
  <xs:element name=\"pre_mortem\">
    <xs:complexType>
      <xs:sequence>
        <xs:element name=\"failure_modes\">
          <xs:complexType>
            <xs:sequence>
              <xs:element name=\"mode\" type=\"xs:string\" minOccurs=\"0\" maxOccurs=\"unbounded\"/>
            </xs:sequence>
          </xs:complexType>
        </xs:element>
        <xs:element name=\"blind_spots\">
          <xs:complexType>
            <xs:sequence>
              <xs:element name=\"assumption\" type=\"xs:string\" minOccurs=\"0\" maxOccurs=\"unbounded\"/>
            </xs:sequence>
          </xs:complexType>
        </xs:element>
        <xs:element name=\"dependencies_at_risk\">
          <xs:complexType>
            <xs:sequence>
              <xs:element name=\"dependency\" type=\"xs:string\" minOccurs=\"0\" maxOccurs=\"unbounded\"/>
            </xs:sequence>
          </xs:complexType>
        </xs:element>
        <xs:element name=\"information_gaps\">
          <xs:complexType>
            <xs:sequence>
              <xs:element name=\"gap\" type=\"xs:string\" minOccurs=\"0\" maxOccurs=\"unbounded\"/>
            </xs:sequence>
          </xs:complexType>
        </xs:element>
      </xs:sequence>
    </xs:complexType>
  </xs:element>
</xs:schema>"

pub const pre_mortem_example = "<pre_mortem>
  <failure_modes>
    <mode>Data source may be behind a paywall</mode>
    <mode>API rate limits could block extraction</mode>
  </failure_modes>
  <blind_spots>
    <assumption>Assuming CSO data is current for Q1 2026</assumption>
    <assumption>Assuming one search will find all competitors</assumption>
  </blind_spots>
  <dependencies_at_risk>
    <dependency>Web search tool availability</dependency>
  </dependencies_at_risk>
  <information_gaps>
    <gap>Unknown whether competitors publish pricing publicly</gap>
  </information_gaps>
</pre_mortem>"

// ---------------------------------------------------------------------------
// Post-mortem schema — quality evaluation after task completion
// ---------------------------------------------------------------------------

pub const post_mortem_xsd = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<xs:schema xmlns:xs=\"http://www.w3.org/2001/XMLSchema\">
  <xs:element name=\"post_mortem\">
    <xs:complexType>
      <xs:sequence>
        <xs:element name=\"verdict\" type=\"xs:string\"/>
        <xs:element name=\"prediction_comparisons\" minOccurs=\"0\">
          <xs:complexType>
            <xs:sequence>
              <xs:element name=\"comparison\" minOccurs=\"0\" maxOccurs=\"unbounded\">
                <xs:complexType>
                  <xs:sequence>
                    <xs:element name=\"prediction\" type=\"xs:string\"/>
                    <xs:element name=\"reality\" type=\"xs:string\"/>
                    <xs:element name=\"accurate\" type=\"xs:string\"/>
                  </xs:sequence>
                </xs:complexType>
              </xs:element>
            </xs:sequence>
          </xs:complexType>
        </xs:element>
        <xs:element name=\"lessons_learned\">
          <xs:complexType>
            <xs:sequence>
              <xs:element name=\"lesson\" type=\"xs:string\" minOccurs=\"0\" maxOccurs=\"unbounded\"/>
            </xs:sequence>
          </xs:complexType>
        </xs:element>
        <xs:element name=\"contributing_factors\">
          <xs:complexType>
            <xs:sequence>
              <xs:element name=\"factor\" type=\"xs:string\" minOccurs=\"0\" maxOccurs=\"unbounded\"/>
            </xs:sequence>
          </xs:complexType>
        </xs:element>
      </xs:sequence>
    </xs:complexType>
  </xs:element>
</xs:schema>"

pub const post_mortem_example = "<post_mortem>
  <verdict>partially_achieved</verdict>
  <prediction_comparisons>
    <comparison>
      <prediction>Data source may be behind a paywall</prediction>
      <reality>Two of three sources required login</reality>
      <accurate>true</accurate>
    </comparison>
    <comparison>
      <prediction>API rate limits could block extraction</prediction>
      <reality>No rate limits encountered</reality>
      <accurate>false</accurate>
    </comparison>
  </prediction_comparisons>
  <lessons_learned>
    <lesson>Always check for login requirements before planning extraction</lesson>
    <lesson>CSO data was current but Eurostat lagged by one quarter</lesson>
  </lessons_learned>
  <contributing_factors>
    <factor>Two of three competitor pricing pages required authentication</factor>
    <factor>Researcher agent adapted by using cached search snippets</factor>
  </contributing_factors>
</post_mortem>"

// ---------------------------------------------------------------------------
// Endeavour post-mortem schema — synthesis across task post-mortems
// ---------------------------------------------------------------------------

pub const endeavour_post_mortem_xsd = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<xs:schema xmlns:xs=\"http://www.w3.org/2001/XMLSchema\">
  <xs:element name=\"endeavour_post_mortem\">
    <xs:complexType>
      <xs:sequence>
        <xs:element name=\"verdict\" type=\"xs:string\"/>
        <xs:element name=\"goal_achieved\" type=\"xs:string\"/>
        <xs:element name=\"criteria_results\" minOccurs=\"0\">
          <xs:complexType>
            <xs:sequence>
              <xs:element name=\"criterion\" minOccurs=\"0\" maxOccurs=\"unbounded\">
                <xs:complexType>
                  <xs:sequence>
                    <xs:element name=\"description\" type=\"xs:string\"/>
                    <xs:element name=\"met\" type=\"xs:string\"/>
                    <xs:element name=\"evidence\" type=\"xs:string\"/>
                  </xs:sequence>
                </xs:complexType>
              </xs:element>
            </xs:sequence>
          </xs:complexType>
        </xs:element>
        <xs:element name=\"synthesis\" type=\"xs:string\"/>
      </xs:sequence>
    </xs:complexType>
  </xs:element>
</xs:schema>"

pub const endeavour_post_mortem_example = "<endeavour_post_mortem>
  <verdict>partially_achieved</verdict>
  <goal_achieved>false</goal_achieved>
  <criteria_results>
    <criterion>
      <description>Collect pricing data from 5+ competitors</description>
      <met>false</met>
      <evidence>Only 3 of 5 competitors had publicly accessible pricing</evidence>
    </criterion>
    <criterion>
      <description>Produce comparison table with tier breakdown</description>
      <met>true</met>
      <evidence>Table produced with 3 competitors and 4 pricing tiers each</evidence>
    </criterion>
  </criteria_results>
  <synthesis>The endeavour achieved its analytical goal but fell short on data coverage. Two competitors gate their pricing behind sales calls. Future attempts should include alternative data sources (review sites, press releases).</synthesis>
</endeavour_post_mortem>"

// ---------------------------------------------------------------------------
// 9. Skill conflict classification (skills/conflict.gleam)
// ---------------------------------------------------------------------------

pub const skill_conflict_xsd = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<xs:schema xmlns:xs=\"http://www.w3.org/2001/XMLSchema\">
  <xs:element name=\"conflict\">
    <xs:complexType>
      <xs:sequence>
        <xs:element name=\"kind\">
          <xs:simpleType>
            <xs:restriction base=\"xs:string\">
              <xs:enumeration value=\"complementary\"/>
              <xs:enumeration value=\"redundant\"/>
              <xs:enumeration value=\"supersedes\"/>
              <xs:enumeration value=\"contradictory\"/>
            </xs:restriction>
          </xs:simpleType>
        </xs:element>
        <xs:element name=\"reasoning\" type=\"xs:string\"/>
      </xs:sequence>
    </xs:complexType>
  </xs:element>
</xs:schema>"

pub const skill_conflict_example = "<conflict>
  <kind>complementary</kind>
  <reasoning>The new skill addresses single-fact queries while the existing skill covers multi-source research. They apply to disjoint situations.</reasoning>
</conflict>"

// ---------------------------------------------------------------------------
// 10. Skill body generation (skills/body_gen.gleam)
// ---------------------------------------------------------------------------

pub const skill_body_xsd = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<xs:schema xmlns:xs=\"http://www.w3.org/2001/XMLSchema\">
  <xs:element name=\"skill_body\">
    <xs:complexType>
      <xs:sequence>
        <xs:element name=\"heading\" type=\"xs:string\"/>
        <xs:element name=\"description\" type=\"xs:string\"/>
        <xs:element name=\"guidance\" type=\"xs:string\"/>
      </xs:sequence>
    </xs:complexType>
  </xs:element>
</xs:schema>"

pub const skill_body_example = "<skill_body>
  <heading>Search Tool Selection</heading>
  <description>When to choose brave_answer over web_search for research queries.</description>
  <guidance>For single factual questions, prefer brave_answer (fastest, most accurate single-shot answer). For multi-source research where you need to compare sources, start with web_search for breadth then fetch_url for depth on promising hits.</guidance>
</skill_body>"

// ---------------------------------------------------------------------------
// System prompt fragments
// ---------------------------------------------------------------------------

/// Build an XStructor system prompt from a base prompt, schema, and example.
pub fn build_system_prompt(
  base_prompt: String,
  xsd_schema: String,
  xml_example: String,
) -> String {
  base_prompt <> "

=== STRUCTURED OUTPUT TASK ===

- You must provide structured output in XML format using the XML schema below.
- You are also provided with an example of the expected output in XML.
- You must escape any strings embedded in the XML output as follows:
    ' is replaced with &apos;
    \" is replaced with &quot;
    & is replaced with &amp;
    < is replaced with &lt;
    > is replaced with &gt;
- Your output must be valid XML.
- Respond with ONLY the XML. No JSON, no markdown fences, no preamble, no explanation.

XML SCHEMA (XSD):
" <> xsd_schema <> "

EXAMPLE OUTPUT:
" <> xml_example
}
