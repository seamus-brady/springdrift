//// Scratchpad store — ephemeral per-cycle agent result bag.
////
//// Used by the cognitive loop and team orchestrators to stash agent
//// outputs keyed by cycle_id so that a synthesis turn can read every
//// member's result. Bag semantics — multiple results per cycle key.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import agent/types as agent_types

pub type Table

@external(erlang, "store_ffi", "new_unique_table")
pub fn new_table(name: String, table_type: String) -> Table

@external(erlang, "store_ffi", "delete_table")
pub fn delete_table(table: Table) -> Nil

@external(erlang, "store_ffi", "insert")
pub fn insert(table: Table, key: String, value: agent_types.AgentResult) -> Nil

@external(erlang, "store_ffi", "lookup_bag")
pub fn lookup_bag(table: Table, key: String) -> List(agent_types.AgentResult)

@external(erlang, "store_ffi", "delete_key")
pub fn delete_key(table: Table, key: String) -> Nil
