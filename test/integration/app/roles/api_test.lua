-- Copyright 2021 Kafka-Tarantool-Loader
--
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.

---
--- Created by ashitov.
--- DateTime: 3/10/20 7:16 PM
---
local t = require("luatest")
local g = t.group("integration_api")
local g2 = t.group("api_delta_processing_test")
local g4 = t.group("api.kafka_connector_api_test")
local g5 = t.group("api.storage_ddl_test")
local g6 = t.group("api.delete_scd_sql")
local g7 = t.group("api.get_scd_table_checksum")
local g8 = t.group("api.truncate_space_on_cluster")
local g9 = t.group("api.timeouts_config")
local g10 = t.group("api.ddl_operations")
local g11 = t.group("integration_api_sql")
local g12 = t.group("api.migration")
local g13 = t.group("api.incorrect_bucket_id")

local checks = require("checks")
local helper = require("test.helper.integration")
local cluster = helper.cluster

local fiber = require("fiber")
local tnt_kafka = require("kafka")
local bin_avro_utils = require("app.utils.bin_avro_utils")
local file_utils = require("app.utils.file_utils")

local function assert_http_json_request(method, path, body, expected)
    checks("string", "string", "?table", "table")
    local response = cluster:server("api-1"):http_request(method, path, {
        json = body,
        headers = { ["content-type"] = "application/json; charset=utf-8" },
        raise = false,
    })
    if expected.body then
        t.assert_equals(response.json, expected.body)
        return response.json
    end
    t.assert_equals(response.status, expected.status)

    return response
end

local schema = file_utils.read_file("test/integration/data/schema_ddl.yml")

g2.before_each(function()
    local storage1 = cluster:server("master-1-1").net_box
    local storage2 = cluster:server("master-2-1").net_box
    storage1:call("box.execute", { "truncate table EMPLOYEES_TRANSFER_HIST" })
    storage1:call("box.execute", { "truncate table EMPLOYEES_TRANSFER" })
    storage1:call("box.execute", { "truncate table EMPLOYEES_HOT" })
    storage2:call("box.execute", { "truncate table EMPLOYEES_TRANSFER_HIST" })
    storage2:call("box.execute", { "truncate table EMPLOYEES_TRANSFER" })
    storage2:call("box.execute", { "truncate table EMPLOYEES_HOT" })
end)

g4.before_each(function()
    local kafka = cluster:server("kafka_connector-1").net_box
    kafka:call("box.execute", { "truncate table _KAFKA_TOPIC" })
end)

g6.before_each(function()
    local storage1 = cluster:server("master-1-1").net_box
    local storage2 = cluster:server("master-2-1").net_box
    storage1:call("box.execute", { "truncate table EMPLOYEES_HOT" })
    storage2:call("box.execute", { "truncate table EMPLOYEES_HOT" })
end)

g7.before_each(function()
    local storage1 = cluster:server("master-1-1").net_box
    local storage2 = cluster:server("master-2-1").net_box
    storage1:call("box.execute", { "truncate table EMPLOYEES_HOT" })
    storage1:call("box.execute", { "truncate table EMPLOYEES_TRANSFER_HIST" })
    storage1:call("box.execute", { "truncate table EMPLOYEES_TRANSFER" })
    storage2:call("box.execute", { "truncate table EMPLOYEES_HOT" })
    storage2:call("box.execute", { "truncate table EMPLOYEES_TRANSFER_HIST" })
    storage2:call("box.execute", { "truncate table EMPLOYEES_TRANSFER" })
end)

g.after_all(function()
    local storage1 = cluster:server("master-1-1").net_box
    storage1:call("box.execute", { "truncate table USER1" })
    storage1:call("box.execute", { "truncate table EMPLOYEES_TRANSFER" })
end)

g.before_test("test_simple_select_query", function()
    local api = cluster:server("api-1").net_box

    local r, err = api:call("insert_record", { "EMPLOYEES_TRANSFER", { 1, 1, 1, 1, "123", "123", "123", 100 } })
    t.assert_equals(err, nil)
    t.assert_equals(r, 1)
end)

g.test_set_ddl = function()
    local net_box = cluster:server("api-1").net_box
    local _, err = net_box:call("set_ddl", { schema })
    t.assert_equals(err, nil)
end

g.test_simple_insert_query = function()
    local storage = cluster:server("master-1-1").net_box
    storage.space.USER1:replace({ 1, "John", "Doe", "johndoe@example.com", 7729 })
end

g.test_simple_select_query = function()
    local net_box = cluster:server("api-1").net_box
    local res, err = net_box:call("query", { [[select * from EMPLOYEES_TRANSFER where "id" = 1]] })

    t.assert_equals(err, nil)

    t.assert_equals(res.rows, { { 1, 1, 1, 1, "123", "123", "123", 100, 3940 } })
end

g.test_cluster_schema_update = function()
    local net_box = cluster:server("api-1").net_box
    local storage = cluster:server("master-1-1")

    local _, err = storage.net_box:eval([[
    s = box.schema.space.create('user2');

    s:format({
          {name = 'id', type = 'unsigned'},
          {name = 'band_name', type = 'string'},
          {name = 'year', type = 'unsigned'}
          });

    s:create_index('primary', {
    type = 'hash',
    parts = {'id'}
    });
    ]])

    t.assert_equals(err, nil)

    local storage_uri = tostring(storage.advertise_uri)

    local _, err = net_box:call("sync_ddl_schema_with_storage", { storage_uri }, { timeout = 30 })
    -- No support redundant argument \"nullable_action\""
    t.assert_equals(err, nil)
    local new_config = cluster:download_config()

    local user2_schema = {
        user2 = {
            engine = "memtx",
            format = {
                { is_nullable = false, name = "id", type = "unsigned" },
                { is_nullable = false, name = "band_name", type = "string" },
                { is_nullable = false, name = "year", type = "unsigned" },
            },
            indexes = {
                {
                    name = "primary",
                    parts = { { is_nullable = false, path = "id", type = "unsigned" } },
                    type = "HASH",
                    unique = true,
                },
            },
            is_local = false,
            temporary = false,
        },
    }

    t.assert_covers(new_config.schema.spaces, user2_schema)
end

g.test_api_get_config = function()
    local _ = cluster:server("api-1").net_box

    local _ = assert_http_json_request(
        "GET",
        "/api/get_config",
        nil,
        { body = file_utils.read_file("/test/integration/data/api/get_config_response.json"), status = 200 }
    )
end

g.test_api_metrics_get_all = function()
    local _ = cluster:server("api-1").net_box
    --TODO Add test
end

g2.test_100k_transfer_data_to_historical_scd_on_cluster = function()
    local storage1 = cluster:server("master-1-1").net_box
    local storage2 = cluster:server("master-2-1").net_box
    local api = cluster:server("api-1").net_box

    local function datagen(storage, number_of_rows) --TODO Move in helper functions
        for i = 1, number_of_rows, 1 do
            storage.space.EMPLOYEES_HOT:insert({ i, 1, "123", "123", "123", 100, 0, 100 }) --TODO Bucket_id fix?
        end
    end

    datagen(storage1, 100000)
    datagen(storage2, 100000)

    local res, err = api:call(
        "transfer_data_to_scd_table_on_cluster",
        { "EMPLOYEES_HOT", "EMPLOYEES_TRANSFER", "EMPLOYEES_TRANSFER_HIST", 1 }
    )

    local cnt1_1 = storage1:call("storage_space_count", { "EMPLOYEES_HOT" })
    local cnt1_2 = storage1:call("storage_space_count", { "EMPLOYEES_TRANSFER" })
    local cnt1_3 = storage1:call("storage_space_count", { "EMPLOYEES_TRANSFER_HIST" })

    local cnt2_1 = storage2:call("storage_space_count", { "EMPLOYEES_HOT" })
    local cnt2_2 = storage2:call("storage_space_count", { "EMPLOYEES_TRANSFER" })
    local cnt2_3 = storage2:call("storage_space_count", { "EMPLOYEES_TRANSFER_HIST" })

    t.assert_equals(err, nil)
    t.assert_equals(res, true)
    t.assert_equals(cnt1_1, 0)
    t.assert_equals(cnt1_2, 100000)
    t.assert_equals(cnt1_3, 0)
    t.assert_equals(cnt2_1, 0)
    t.assert_equals(cnt2_2, 100000)
    t.assert_equals(cnt2_3, 0)

    datagen(storage1, 100000)
    datagen(storage2, 100000)

    local res, err = api:call(
        "transfer_data_to_scd_table_on_cluster",
        { "EMPLOYEES_HOT", "EMPLOYEES_TRANSFER", "EMPLOYEES_TRANSFER_HIST", 2 }
    )

    local cnt1_1 = storage1:call("storage_space_count", { "EMPLOYEES_HOT" })
    local cnt1_2 = storage1:call("storage_space_count", { "EMPLOYEES_TRANSFER" })
    local cnt1_3 = storage1:call("storage_space_count", { "EMPLOYEES_TRANSFER_HIST" })

    local cnt2_1 = storage2:call("storage_space_count", { "EMPLOYEES_HOT" })
    local cnt2_2 = storage2:call("storage_space_count", { "EMPLOYEES_TRANSFER" })
    local cnt2_3 = storage2:call("storage_space_count", { "EMPLOYEES_TRANSFER_HIST" })

    t.assert_equals(err, nil)
    t.assert_equals(res, true)
    t.assert_equals(cnt1_1, 0)
    t.assert_equals(cnt1_2, 100000)
    t.assert_equals(cnt1_3, 100000)
    t.assert_equals(cnt2_1, 0)
    t.assert_equals(cnt2_2, 100000)
    t.assert_equals(cnt2_3, 100000)
end

g2.test_rest_api_error_transfer_data_to_scd_table_on_cluster = function()
    local _ = assert_http_json_request(
        "GET",
        -- luacheck: max line length 180
        "/api/etl/transfer_data_to_scd_table?_stage_data_table_name=EMPLOYEES_HOT&_historical_data_table_name=EMPLOYEES_TRANSFER_HIST&_delta_number=2",
        nil,
        {
            body = {
                error = "ERROR: _actual_data_table_name param in query not found",
                errorCode = "API_ETL_TRANSFER_DATA_TO_HISTORICAL_TABLE_001",
                status = "error",
            },
            status = 400,
        }
    )

    local _ = assert_http_json_request(
        "GET",
        "/api/etl/transfer_data_to_scd_table?_stage_data_table_name=EMPLOYEES_HOT&_actual_data_table_name=EMPLOYEES_TRANSFER&_delta_number=2",
        nil,
        {
            body = {
                error = "ERROR: _historical_data_table_name param in query not found",
                errorCode = "API_ETL_TRANSFER_DATA_TO_HISTORICAL_TABLE_002",
                status = "error",
            },
            status = 400,
        }
    )

    local _ = assert_http_json_request(
        "GET",
        -- luacheck: max line length 200
        "/api/etl/transfer_data_to_scd_table?_stage_data_table_name=EMPLOYEES_HOT&_actual_data_table_name=EMPLOYEES_TRANSFER&_historical_data_table_name=EMPLOYEES_TRANSFER_HIST",
        nil,
        {
            body = {
                error = "ERROR: _delta_number param in query not found",
                errorCode = "API_ETL_TRANSFER_DATA_TO_HISTORICAL_TABLE_003",
                status = "error",
            },
            status = 400,
        }
    )

    local _ = assert_http_json_request(
        "GET",
        "/api/etl/transfer_data_to_scd_table?_actual_data_table_name=EMPLOYEES_TRANSFER2&_historical_data_table_name=EMPLOYEES_TRANSFER_HIST&_delta_number=2",
        nil,
        {
            body = {
                error = "ERROR: _stage_data_table_name param in query not found",
                errorCode = "API_ETL_TRANSFER_DATA_TO_SCD_TABLE_001",
                status = "error",
            },
            status = 400,
        }
    )

    local _ = assert_http_json_request(
        "GET",
        "/api/etl/transfer_data_to_scd_table?_stage_data_table_name=EMPLOYEES_HOT&_actual_data_table_name=EMPLOYEES_TRANSFER2&_historical_data_table_name=EMPLOYEES_TRANSFER_HIST&_delta_number=2",
        nil,
        {
            body = {
                error = "ERROR: No such space",
                errorCode = "STORAGE_001",
                opts = {
                    error = "ERROR: No such space",
                    errorCode = "STORAGE_001",
                    opts = { space = "EMPLOYEES_TRANSFER2" },
                    status = "error",
                },
                status = "error",
            },
            status = 400,
        }
    )
end

g4.test_subscription_api = function()
    assert_http_json_request("POST", "/api/v1/kafka/subscription", { maxNumberOfMessagesPerPartition = 10000 }, {
        body = {
            code = "API_KAFKA_SUBSCRIPTION_001",
            message = "ERROR: topicName param not found in the query.",
        },
        status = 400,
    })

    assert_http_json_request("POST", "/api/v1/kafka/subscription", { topicName = "123" }, {
        body = {
            code = "API_KAFKA_SUBSCRIPTION_002",
            message = "ERROR: maxNumberOfMessagesPerPartition param not found in the query.",
        },
        status = 400,
    })

    assert_http_json_request("POST", "/api/v1/kafka/subscription", {
        topicName = "EMPLOYEES",
        spaceNames = { "EMPLOYEES_HOT" },
        avroSchema = "null",
        maxNumberOfMessagesPerPartition = 100,
        maxIdleSecondsBeforeCbCall = 100,
        callbackFunction = {
            callbackFunctionName = "transfer_data_to_scd_table_on_cluster_cb",
            callbackFunctionParams = {
                _space = "EMPLOYEES_HOT",
                _stage_data_table_name = "EMPLOYEES_HOT",
                _actual_data_table_name = "EMPLOYEES",
                _historical_data_table_name = "EMPLOYEES_HIST",
                _delta_number = 40,
            },
        },
    }, {
        status = 200,
    })

    assert_http_json_request("POST", "/api/v1/kafka/subscription", {
        topicName = "EMPLOYEES",
        spaceNames = { "EMPLOYEES_HOT" },
        avroSchema = { type = "long" },
        maxNumberOfMessagesPerPartition = 100,
        maxIdleSecondsBeforeCbCall = 100,
        callbackFunction = {
            callbackFunctionName = "transfer_data_to_scd_table_on_cluster_cb",
            callbackFunctionParams = {
                _space = "EMPLOYEES_HOT",
                _stage_data_table_name = "EMPLOYEES_HOT",
                _actual_data_table_name = "EMPLOYEES",
                _historical_data_table_name = "EMPLOYEES_HIST",
                _delta_number = 40,
            },
        },
    }, {
        status = 200,
    })
end

g4.test_dataload_api = function() end

g5.test_get_storage_space_schema = function()
    local api = cluster:server("api-1").net_box

    local res = api:call("get_storage_space_schema", { { "RANDOM_SPACE" } })
    t.assert_equals(type(res), "string")
    t.assert(string.len(res) > 0)

    local res2 = api:call("get_storage_space_schema", { { "EMPLOYEES_HOT" } })
    t.assert_equals(type(res2), "string")
    t.assert(string.len(res2) > 0)
end

g6.test_delete_scd_sql_on_cluster = function()
    local api = cluster:server("api-1").net_box
    local storage1 = cluster:server("master-1-1").net_box
    local storage2 = cluster:server("master-2-1").net_box

    local function datagen(storage, number_of_rows) --TODO Move in helper functions
        for i = 1, number_of_rows, 1 do
            storage.space.EMPLOYEES_HOT:insert({ i, 1, "123", "123", "123", 100, 0, 100 }) --TODO Bucket_id fix?
        end
    end

    datagen(storage1, 1000)
    datagen(storage2, 1000)

    local cnt1_before = storage1:call("storage_space_count", { "EMPLOYEES_HOT" })
    local cnt2_before = storage2:call("storage_space_count", { "EMPLOYEES_HOT" })

    t.assert_equals(cnt1_before, 1000)
    t.assert_equals(cnt2_before, 1000)

    local _, err_truncate = api:call("delete_data_from_scd_table_sql_on_cluster", { "EMPLOYEES_HOT" })

    t.assert_equals(err_truncate, nil)

    local cnt1_after_truncate = storage1:call("storage_space_count", { "EMPLOYEES_HOT" })
    local cnt2_after_truncate = storage2:call("storage_space_count", { "EMPLOYEES_HOT" })

    t.assert_equals(cnt1_after_truncate, 0)
    t.assert_equals(cnt2_after_truncate, 0)

    datagen(storage1, 10000)
    datagen(storage2, 10000)

    local _, err_delete_half = api:call(
        "delete_data_from_scd_table_sql_on_cluster",
        { "EMPLOYEES_HOT", '"id" >= 5001' }
    )

    t.assert_equals(err_delete_half, nil)

    local cnt1_after_half_1 = storage1:call("storage_space_count", { "EMPLOYEES_HOT" })
    local cnt2_after_half_2 = storage2:call("storage_space_count", { "EMPLOYEES_HOT" })
    t.assert_equals(cnt1_after_half_1, 5000)
    t.assert_equals(cnt2_after_half_2, 5000)

    local _, err_delete_another = api:call(
        "delete_data_from_scd_table_sql_on_cluster",
        { "EMPLOYEES_HOT", [["name" = '123']] }
    )

    t.assert_equals(err_delete_another, nil)

    local cnt1_after_another_1 = storage1:call("storage_space_count", { "EMPLOYEES_HOT" })
    local cnt2_after_another_2 = storage2:call("storage_space_count", { "EMPLOYEES_HOT" })
    t.assert_equals(cnt1_after_another_1, 0)
    t.assert_equals(cnt2_after_another_2, 0)
end

g6.test_delete_scd_sql_on_cluster_rest = function()
    local _ = cluster:server("api-1").net_box
    local storage1 = cluster:server("master-1-1").net_box
    local storage2 = cluster:server("master-2-1").net_box

    local function datagen(storage, number_of_rows) --TODO Move in helper functions
        for i = 1, number_of_rows, 1 do
            storage.space.EMPLOYEES_HOT:insert({ i, 1, "123", "123", "123", 100, 0, 100 }) --TODO Bucket_id fix?
        end
    end

    datagen(storage1, 1000)
    datagen(storage2, 1000)

    local cnt1_before = storage1:call("storage_space_count", { "EMPLOYEES_HOT" })
    local cnt2_before = storage2:call("storage_space_count", { "EMPLOYEES_HOT" })

    t.assert_equals(cnt1_before, 1000)
    t.assert_equals(cnt2_before, 1000)

    assert_http_json_request("POST", "/api/etl/delete_data_from_scd_table", { spaceName = "c" }, { status = 500 })

    assert_http_json_request(
        "POST",
        "/api/etl/delete_data_from_scd_table",
        { spaceName = "EMPLOYEES_HOT", whereCondition = [["name1234" = '123']] },
        { status = 500 }
    )

    assert_http_json_request(
        "POST",
        "/api/etl/delete_data_from_scd_table",
        { spaceName = "EMPLOYEES_HOT", whereCondition = [["name" = '123']] },
        { status = 200 }
    )

    local cnt1_after_truncate = storage1:call("storage_space_count", { "EMPLOYEES_HOT" })
    local cnt2_after_truncate = storage2:call("storage_space_count", { "EMPLOYEES_HOT" })

    t.assert_equals(cnt1_after_truncate, 0)
    t.assert_equals(cnt2_after_truncate, 0)
end

g7.test_get_scd_checksum_on_cluster_wo_columns = function()
    local api = cluster:server("api-1").net_box
    local storage1 = cluster:server("master-1-1").net_box
    local storage2 = cluster:server("master-2-1").net_box

    local function datagen(storage, number_of_rows) --TODO Move in helper functions
        for i = 1, number_of_rows, 1 do
            storage.space.EMPLOYEES_HOT:insert({ i, 1, "123", "123", "123", 100, 0, 100 }) --TODO Bucket_id fix?
        end
    end

    datagen(storage1, 1000)
    datagen(storage2, 1000)
    local is_gen, res = api:call(
        "get_scd_table_checksum_on_cluster",
        { "EMPLOYEES_TRANSFER", "EMPLOYEES_TRANSFER_HIST", 1 }
    )
    t.assert_equals(is_gen, true)
    t.assert_equals(res, 0)

    api:call(
        "transfer_data_to_scd_table_on_cluster",
        { "EMPLOYEES_HOT", "EMPLOYEES_TRANSFER", "EMPLOYEES_TRANSFER_HIST", 1 }
    )

    local is_gen2, res2 = api:call(
        "get_scd_table_checksum_on_cluster",
        { "EMPLOYEES_TRANSFER", "EMPLOYEES_TRANSFER_HIST", 1 }
    )
    t.assert_equals(is_gen2, true)
    t.assert_equals(res2, 2000)

    datagen(storage1, 1000)
    datagen(storage2, 1000)
    api:call(
        "transfer_data_to_scd_table_on_cluster",
        { "EMPLOYEES_HOT", "EMPLOYEES_TRANSFER", "EMPLOYEES_TRANSFER_HIST", 2 }
    )

    local is_gen3, res3 = api:call(
        "get_scd_table_checksum_on_cluster",
        { "EMPLOYEES_TRANSFER", "EMPLOYEES_TRANSFER_HIST", 1 }
    )
    t.assert_equals(is_gen3, true)
    t.assert_equals(res3, 2000)

    local is_gen4, res4 = api:call(
        "get_scd_table_checksum_on_cluster",
        { "EMPLOYEES_TRANSFER", "EMPLOYEES_TRANSFER_HIST", 2 }
    )
    t.assert_equals(is_gen4, true)
    t.assert_equals(res4, 2000)
end

g7.test_get_scd_checksum_on_cluster_w_columns = function()
    local api = cluster:server("api-1").net_box
    local storage1 = cluster:server("master-1-1").net_box
    local storage2 = cluster:server("master-2-1").net_box

    local function datagen(storage, number_of_rows) --TODO Move in helper functions
        for i = 1, number_of_rows, 1 do
            storage.space.EMPLOYEES_HOT:insert({ i, 1, "123", "123", "123", 100, 0, 100 }) --TODO Bucket_id fix?
        end
    end

    datagen(storage1, 1000)
    datagen(storage2, 1000)
    local is_gen, res = api:call(
        "get_scd_table_checksum_on_cluster",
        { "EMPLOYEES_TRANSFER", "EMPLOYEES_TRANSFER_HIST", 1, { "id", "sysFrom" } }
    )
    t.assert_equals(is_gen, true)
    t.assert_equals(res, 0)
    api:call(
        "transfer_data_to_scd_table_on_cluster",
        { "EMPLOYEES_HOT", "EMPLOYEES_TRANSFER", "EMPLOYEES_TRANSFER_HIST", 1 }
    )
    local is_gen2, res2 = api:call(
        "get_scd_table_checksum_on_cluster",
        { "EMPLOYEES_TRANSFER", "EMPLOYEES_TRANSFER_HIST", 1, { "id", "sysFrom" } }
    )
    t.assert_equals(is_gen2, true)
    t.assert_equals(res2, 2363892561778)
    datagen(storage1, 1000)
    datagen(storage2, 1000)
    api:call(
        "transfer_data_to_scd_table_on_cluster",
        { "EMPLOYEES_HOT", "EMPLOYEES_TRANSFER", "EMPLOYEES_TRANSFER_HIST", 2 }
    )

    local is_gen3, res3 = api:call(
        "get_scd_table_checksum_on_cluster",
        { "EMPLOYEES_TRANSFER", "EMPLOYEES_TRANSFER_HIST", 1, { "id", "sysFrom" } }
    )
    t.assert_equals(is_gen3, true)
    t.assert_equals(res3, 2363892561778)

    local is_gen4, res4 = api:call(
        "get_scd_table_checksum_on_cluster",
        { "EMPLOYEES_TRANSFER", "EMPLOYEES_TRANSFER_HIST", 2, { "id", "sysFrom" } }
    )
    t.assert_equals(is_gen4, true)
    t.assert_equals(res4, 2360082553404)
end

g7.test_get_scd_norm_checksum_on_cluster_w_columns = function()
    local api = cluster:server("api-1").net_box
    local storage1 = cluster:server("master-1-1").net_box
    local storage2 = cluster:server("master-2-1").net_box

    local function datagen(storage, number_of_rows) --TODO Move in helper functions
        for i = 1, number_of_rows, 1 do
            storage.space.EMPLOYEES_HOT:insert({ i, 1, "123", "123", "123", 100, 0, 100 }) --TODO Bucket_id fix?
        end
    end

    datagen(storage1, 1000)
    datagen(storage2, 1000)
    local is_gen, res = api:call(
        "get_scd_table_checksum_on_cluster",
        { "EMPLOYEES_TRANSFER", "EMPLOYEES_TRANSFER_HIST", 1, { "id", "sysFrom" }, 2000000 }
    )
    t.assert_equals(is_gen, true)
    t.assert_equals(res, 0)
    api:call(
        "transfer_data_to_scd_table_on_cluster",
        { "EMPLOYEES_HOT", "EMPLOYEES_TRANSFER", "EMPLOYEES_TRANSFER_HIST", 1 }
    )
    local is_gen2, res2 = api:call(
        "get_scd_table_checksum_on_cluster",
        { "EMPLOYEES_TRANSFER", "EMPLOYEES_TRANSFER_HIST", 1, { "id", "sysFrom" }, 2000000 }
    )
    t.assert_equals(is_gen2, true)
    t.assert_equals(res2, 1180948)
    datagen(storage1, 1000)
    datagen(storage2, 1000)
    api:call(
        "transfer_data_to_scd_table_on_cluster",
        { "EMPLOYEES_HOT", "EMPLOYEES_TRANSFER", "EMPLOYEES_TRANSFER_HIST", 2 }
    )

    local is_gen3, res3 = api:call(
        "get_scd_table_checksum_on_cluster",
        { "EMPLOYEES_TRANSFER", "EMPLOYEES_TRANSFER_HIST", 1, { "id", "sysFrom" }, 2000000 }
    )
    t.assert_equals(is_gen3, true)
    t.assert_equals(res3, 1180948)

    local is_gen4, res4 = api:call(
        "get_scd_table_checksum_on_cluster",
        { "EMPLOYEES_TRANSFER", "EMPLOYEES_TRANSFER_HIST", 2, { "id", "sysFrom" }, 2000000 }
    )
    t.assert_equals(is_gen4, true)
    t.assert_equals(res4, 1179046)
end

g7.test_get_scd_checksum_on_cluster_rest = function()
    local api = cluster:server("api-1").net_box
    local storage1 = cluster:server("master-1-1").net_box
    local storage2 = cluster:server("master-2-1").net_box

    local function datagen(storage, number_of_rows) --TODO Move in helper functions
        for i = 1, number_of_rows, 1 do
            storage.space.EMPLOYEES_HOT:insert({ i, 1, "123", "123", "123", 100, 0, 100 }) --TODO Bucket_id fix?
        end
    end

    datagen(storage1, 1000)
    datagen(storage2, 1000)

    assert_http_json_request(
        "POST",
        "/api/etl/get_scd_table_checksum",
        { historicalDataTableName = "c", sysCn = 666 },
        { status = 500 }
    )

    assert_http_json_request(
        "POST",
        "/api/etl/get_scd_table_checksum",
        { actualDataTableName = "c", sysCn = 666 },
        { status = 500 }
    )

    assert_http_json_request(
        "POST",
        "/api/etl/get_scd_table_checksum",
        { actualDataTableName = "c", historicalDataTableName = "c" },
        { status = 500 }
    )

    assert_http_json_request(
        "POST",
        "/api/etl/get_scd_table_checksum",
        { actualDataTableName = "EMPLOYEES_TRANSFER", historicalDataTableName = "EMPLOYEES_TRANSFER_HIST", sysCn = 1 },
        { status = 200 }
    )

    api:call(
        "transfer_data_to_scd_table_on_cluster",
        { "EMPLOYEES_HOT", "EMPLOYEES_TRANSFER", "EMPLOYEES_TRANSFER_HIST", 1 }
    )

    assert_http_json_request(
        "POST",
        "/api/etl/get_scd_table_checksum",
        { actualDataTableName = "EMPLOYEES_TRANSFER", historicalDataTableName = "EMPLOYEES_TRANSFER_HIST", sysCn = 1 },
        { status = 200, body = { checksum = 2000 } }
    )

    assert_http_json_request("POST", "/api/etl/get_scd_table_checksum", {
        actualDataTableName = "EMPLOYEES_TRANSFER",
        historicalDataTableName = "EMPLOYEES_TRANSFER_HIST",
        columnList = { "id", "sysFrom" },
        sysCn = 1,
    }, {
        status = 200,
        body = { checksum = 2363892561778 },
    })

    assert_http_json_request("POST", "/api/etl/get_scd_table_checksum", {
        actualDataTableName = "EMPLOYEES_TRANSFER",
        historicalDataTableName = "EMPLOYEES_TRANSFER_HIST",
        columnList = { "id", "sysFrom" },
        sysCn = 1,
        normalization = 2000000,
    }, {
        status = 200,
        body = { checksum = 1180948 },
    })
end

g8.test_truncate_existing_spaces_on_cluster = function()
    local storage1 = cluster:server("master-1-1").net_box
    local storage2 = cluster:server("master-2-1").net_box
    local api = cluster:server("api-1").net_box

    -- refresh net.box schema metadata
    storage1:eval("return true")
    storage2:eval("return true")

    local function datagen(storage, number_of_rows, bucket_id)
        for i = 1, number_of_rows, 1 do
            storage.space.TRUNCATE_TABLE:insert({ i, bucket_id })
        end
    end

    datagen(storage1, 1000, 1)
    datagen(storage2, 1000, 2)

    local res, err = api:call("truncate_space_on_cluster", { "TRUNCATE_TABLE", false })

    local count_1 = storage1:call("storage_space_count", { "TRUNCATE_TABLE" })
    local count_2 = storage1:call("storage_space_count", { "TRUNCATE_TABLE" })

    t.assert_equals(err, nil)
    t.assert_equals(res, true)
    t.assert_equals(count_1, 0)
    t.assert_equals(count_2, 0)
end

g8.test_truncate_existing_spaces_on_cluster_post = function()
    local storage1 = cluster:server("master-1-1").net_box
    local storage2 = cluster:server("master-2-1").net_box
    local api = cluster:server("api-1").net_box

    storage1:eval("return true")
    storage2:eval("return true")

    local function datagen(storage, number_of_rows, bucket_id)
        for i = 1, number_of_rows, 1 do
            storage.space.TRUNCATE_TABLE:insert({ i, bucket_id })
        end
    end

    datagen(storage1, 1000, 1)
    datagen(storage2, 1000, 2)

    assert_http_json_request(
        "POST",
        "/api/etl/truncate_space_on_cluster",
        { spaceName = "TRUNCATE_TABLE" },
        { status = 200 }
    )

    local res, err = api:call("truncate_space_on_cluster", { "TRUNCATE_TABLE", false })

    local count_1 = storage1:call("storage_space_count", { "TRUNCATE_TABLE" })
    local count_2 = storage1:call("storage_space_count", { "TRUNCATE_TABLE" })

    t.assert_equals(err, nil)
    t.assert_equals(res, true)
    t.assert_equals(count_1, 0)
    t.assert_equals(count_2, 0)
end

g9.before_each(function()
    local storage1 = cluster:server("master-1-1").net_box
    local storage2 = cluster:server("master-2-1").net_box
    storage1:call("box.execute", { "truncate table EMPLOYEES_TRANSFER_HIST" })
    storage1:call("box.execute", { "truncate table EMPLOYEES_TRANSFER" })
    storage1:call("box.execute", { "truncate table EMPLOYEES_HOT" })
    storage2:call("box.execute", { "truncate table EMPLOYEES_TRANSFER_HIST" })
    storage2:call("box.execute", { "truncate table EMPLOYEES_TRANSFER" })
    storage2:call("box.execute", { "truncate table EMPLOYEES_HOT" })
end)

g9.before_all(function()
    local config = cluster:download_config()

    config["api_timeout"] = {
        ["transfer_stage_data_to_scd_tbl"] = 1,
    }

    cluster:upload_config(config)
end)

g9.after_all(function()
    local config = cluster:download_config()

    config["api_timeout"] = nil

    cluster:upload_config(config)

    local storage1 = cluster:server("master-1-1").net_box
    local storage2 = cluster:server("master-2-1").net_box

    -- it needs because url handler works async and after request with error continue reload data from staging table
    -- if didn't truncate in other test may race condition
    storage1:call("box.execute", { "truncate table EMPLOYEES_HOT" })
    storage2:call("box.execute", { "truncate table EMPLOYEES_HOT" })
end)

g9.test_timeout_cfg = function()
    local function datagen(storage, number_of_rows)
        for i = 1, number_of_rows, 1 do
            storage.space.EMPLOYEES_HOT:insert({ i, 1, "123", "123", "123", 100, 0, 100 })
        end
    end

    local storage1 = cluster:server("master-1-1").net_box
    local storage2 = cluster:server("master-2-1").net_box
    datagen(storage1, 10000)
    datagen(storage2, 10000)

    -- luacheck: max line length 210
    local url =
        "/api/etl/transfer_data_to_scd_table?_stage_data_table_name=EMPLOYEES_HOT&_actual_data_table_name=EMPLOYEES_TRANSFER&_historical_data_table_name=EMPLOYEES_TRANSFER_HIST&_delta_number=2"
    assert_http_json_request("GET", url, nil, {
        body = {
            error = "ERROR: data modification error",
            errorCode = "STORAGE_003",
            opts = {
                error = "ERROR: data modification error",
                errorCode = "STORAGE_003",
                opts = {
                    actual_data_table_name = "EMPLOYEES_TRANSFER",
                    delta_number = 2,
                    error = "Response is not ready",
                    func = "transfer_stage_data_to_scd_table",
                    historical_data_table_name = "EMPLOYEES_TRANSFER_HIST",
                    stage_data_table_name = "EMPLOYEES_HOT",
                },
                status = "error",
            },
            status = "error",
        },
        status = 400,
    })
end

g10.before_test("test_timeout_error_ddl", function()
    local config = cluster:download_config()

    config["api_timeout"] = {
        ddl_operation = 0.1,
    }

    cluster:upload_config(config)
end)

g10.after_all(function()
    local config = cluster:download_config()

    config["api_timeout"] = nil

    cluster:upload_config(config)
end)

g10.test_create_and_delete_api = function()
    assert_http_json_request("POST", "/api/v1/ddl/table/queuedCreate", {
        spaces = {
            adg_test_actual = {
                format = {
                    {
                        name = "id",
                        type = "integer",
                        is_nullable = false,
                    },
                    {
                        name = "bucket_id",
                        type = "unsigned",
                        is_nullable = false,
                    },
                },
                temporary = false,
                engine = "vinyl",
                indexes = {
                    {
                        unique = true,
                        parts = {
                            {
                                path = "id",
                                type = "integer",
                                is_nullable = false,
                            },
                        },
                        type = "TREE",
                        name = "id",
                    },
                    {
                        unique = false,
                        parts = {
                            {
                                path = "bucket_id",
                                type = "unsigned",
                                is_nullable = false,
                            },
                        },
                        type = "TREE",
                        name = "bucket_id",
                    },
                },
                is_local = false,
                sharding_key = { "id" },
            },
        },
    }, {
        status = 200,
    })

    local c = cluster:download_config()
    t.assert_not_equals(c.schema.spaces.adg_test_actual, nil)

    assert_http_json_request(
        "DELETE",
        "/api/v1/ddl/table/queuedDelete",
        { tableList = { "adg_test_actual" } },
        { status = 200 }
    )

    c = cluster:download_config()
    t.assert_equals(c.schema.spaces.adg_test_actual, nil)
end

g10.test_timeout_error_ddl = function()
    assert_http_json_request("POST", "/api/v1/ddl/table/queuedCreate", {
        spaces = {
            adg_test_actual = {
                format = {
                    {
                        name = "id",
                        type = "integer",
                        is_nullable = false,
                    },
                    {
                        name = "bucket_id",
                        type = "unsigned",
                        is_nullable = false,
                    },
                },
                temporary = false,
                engine = "vinyl",
                indexes = {
                    {
                        unique = true,
                        parts = {
                            {
                                path = "id",
                                type = "integer",
                                is_nullable = false,
                            },
                        },
                        type = "TREE",
                        name = "id",
                    },
                    {
                        unique = false,
                        parts = {
                            {
                                path = "bucket_id",
                                type = "unsigned",
                                is_nullable = false,
                            },
                        },
                        type = "TREE",
                        name = "bucket_id",
                    },
                },
                is_local = false,
                sharding_key = { "id" },
            },
        },
    }, {
        body = { code = "API_DDL_QUEUE_004", message = "ERROR: ddl request timeout" },
        status = 500,
    })
end

g11.after_all(function ()
    local storage1 = cluster:server("master-1-1").net_box
    local storage2 = cluster:server("master-2-1").net_box

    storage1:call("box.execute", { [[truncate table "table_test_1"]] })
    storage2:call("box.execute", { [[truncate table "table_test_1"]] })
    storage1:call("box.execute", { [[truncate table "table_test_2"]] })
    storage2:call("box.execute", { [[truncate table "table_test_2"]] })
    storage1:call("box.execute", { [[truncate table "dev__sales__sales_staging"]] })
    storage2:call("box.execute", { [[truncate table "dev__sales__sales_staging"]] })
end)

g11.test_insert_select_query = function()
    t.skip("manually tested") -- insert isn't support in sbroad now
    local net_box = cluster:server("api-1").net_box

    local res, err = net_box:call("query", {
        [[INSERT INTO "table_test_2"
        ("id", FIRST_NAME, LAST_NAME, EMAIL) VALUES (?, ?, ?, ?);]],
        { 1, "John", "Doe", "johndoe@example.com" },
    })
    t.assert_equals(err, nil)
    t.assert_equals(res.row_count, 1)

    local res, err = net_box:call("query", {
        [[INSERT INTO "table_test_1"
        ("id", FIRST_NAME, LAST_NAME, EMAIL, "bucket_id") SELECT * FROM "table_test_2" WHERE "id" = ?;]],
        { 1 },
    })

    t.assert_equals(err, nil)
    t.assert_equals(res, true)

    local res, err = net_box:call("query", { [[SELECT * FROM "table_test_1" WHERE "id" = 1]], {} })

    t.assert_equals(err, nil)
    t.assert_equals(res.rows, { { 1, "John", "Doe", "johndoe@example.com", 3939 } })
end

g11.test_insert_dtm_query = function()
    t.skip("manually tested") -- insert isn't support in sbroad now
    local net_box = cluster:server("api-1").net_box

    local res, err = net_box:call("query", {
        -- luacheck: max line length 210
        [[insert into "dev__sales__sales_staging" ("identification_number", "transaction_date", "product_code", "product_units", "store_id", "description", "sys_op") values(?,?,?,?,?,?,?);]],
        {1,0,'A',7,1234,'B', 0},
    })

    t.assert_equals(err, nil)
    t.assert_equals(res.row_count, 1)

    res, err = net_box:call("query", {
        -- luacheck: max line length 220
        [[insert into "dev__sales__sales_staging" ("identification_number", "transaction_date", "product_code", "product_units", "store_id", "description", "bucket_id", "sys_op") values(2,0,'A',7,1234,'B',null,0);]],
    })
    t.assert_equals(err, nil)
    t.assert_equals(res.row_count, 1)

    local res, err = net_box:call("query", {
        -- luacheck: max line length 210
        [[insert into "dev__sales__sales_staging" ("identification_number", "transaction_date", "product_code", "product_units", "store_id", "description", "sys_op") values (?,?,?,?,?,?,?), (?,?,?,?,?,?,?);]],
        {3,0,'C',7,1235,'2', 0, 4,0,'D',7,1236,'1', 0},
    })

    t.assert_equals(err, nil)
    t.assert_equals(res.row_count, 2)

end

g12.test_incorrect_body_params = function()
    assert_http_json_request("POST", "/api/v1/ddl/table/migrate/EMPLOYEES", {}, {
        status = 500,
        body = {
            code = "API_MIGRATION_EMPTY_TYPE",
            message = 'ERROR: "operation_type" param not found in the query.',
        },
    })

    assert_http_json_request("POST", "/api/v1/ddl/table/migrate/EMPLOYEES", {
        operation_type = "create_index",
    }, {
        status = 500,
        body = {
            code = "API_MIGRATION_EMPTY_NAME",
            message = 'ERROR: "name" param not found in the query.',
        },
    })

    assert_http_json_request("POST", "/api/v1/ddl/table/migrate/EMPLOYEES", {
        operation_type = "adrt",
        name = "test",
    }, {
        status = 500,
        body = {
            code = "API_MIGRATION_UNKNOWN_TYPE",
            message = "ERROR: unknown migration operation type.",
        },
    })
end

g12.test_index_migration = function()
    local config = cluster:download_config()
    local old_schema = config.schema.spaces["EMPLOYEES"]

    assert_http_json_request("POST", "/api/v1/ddl/table/migrate/EMPLOYEES", {
        operation_type = "create_index",
        name = "test_idx",
        params = {
            type = "TREE",
            unique = false,
            fields = { "FIRST_NAME", "LAST_NAME" },
        },
    }, {
        status = 200,
    })

    config = cluster:download_config()
    local new_schema = config.schema.spaces["EMPLOYEES"]
    t.assert_not_equals(new_schema, old_schema)

    local has_index = false
    for _, rec in pairs(new_schema.indexes) do
        if rec.name == "test_idx" then
            has_index = true
        end
    end
    t.assert_equals(has_index, true)

    assert_http_json_request("POST", "/api/v1/ddl/table/migrate/EMPLOYEES", {
        operation_type = "drop_index",
        name = "test_idx",
    }, {
        status = 200,
    })

    config = cluster:download_config()
    new_schema = config.schema.spaces["EMPLOYEES"]
    t.assert_equals(old_schema, new_schema)
end

g12.test_column_migration = function()
    local config = cluster:download_config()
    local old_schema = config.schema.spaces["EMPLOYEES"]

    assert_http_json_request("POST", "/api/v1/ddl/table/migrate/EMPLOYEES", {
        operation_type = "add_column",
        name = "test_col",
        params = {
            type = "string",
            is_nullable = false,
        },
    }, {
        status = 200,
    })

    config = cluster:download_config()
    local new_schema = config.schema.spaces["EMPLOYEES"]
    t.assert_not_equals(new_schema, old_schema)

    local has_index = false
    for _, rec in pairs(new_schema.format) do
        if rec.name == "test_col" then
            has_index = true
        end
    end
    t.assert_equals(has_index, true)

    assert_http_json_request("POST", "/api/v1/ddl/table/migrate/EMPLOYEES", {
        operation_type = "drop_column",
        name = "test_col",
    }, {
        status = 200,
    })

    config = cluster:download_config()
    new_schema = config.schema.spaces["EMPLOYEES"]
    t.assert_equals(new_schema, old_schema)

    has_index = false
    for _, rec in pairs(new_schema.format) do
        if rec.name == "test_col" then
            has_index = true
        end
    end
    t.assert_equals(has_index, false)
end

g13.test_bucket_id_vinyl_calc = function()
    t.skip("manually tested")
    local storage1 = cluster:server("master-1-1").net_box

    local value_schema, err = file_utils.read_file("test/unit/data/avro_schemas/adg_test_avro_schema.json")
    t.assert_equals(err, nil)

    local producer, err2 = tnt_kafka.Producer.create({ brokers = "kafka:29092" })
    t.assert_equals(err2, nil)

    -- Создать спейс с именем 1, ключом шардирования 1
    assert_http_json_request("POST", "/api/v1/ddl/table/queuedCreate", {
        spaces = {
            adg_test_actual = {
                format = {
                    {
                        name = "id",
                        type = "integer",
                        is_nullable = false,
                    },
                    {
                        name = "int_col",
                        type = "integer",
                        is_nullable = false,
                    },
                    {
                        name = "sysFrom",
                        type = "number",
                        is_nullable = false,
                    },
                    {
                        name = "sysOp",
                        type = "number",
                        is_nullable = false,
                    },
                    {
                        name = "bucket_id",
                        type = "unsigned",
                        is_nullable = true,
                    },
                },
                temporary = false,
                engine = "vinyl",
                indexes = {
                    {
                        unique = true,
                        parts = {
                            {
                                path = "id",
                                type = "integer",
                                is_nullable = false,
                            },
                            {
                                path = "int_col",
                                type = "integer",
                                is_nullable = false,
                            },
                            {
                                path = "sysFrom",
                                type = "number",
                                is_nullable = false,
                            },
                        },
                        type = "TREE",
                        name = "id",
                    },
                    {
                        unique = false,
                        parts = {
                            {
                                path = "bucket_id",
                                type = "unsigned",
                                is_nullable = true,
                            },
                        },
                        type = "TREE",
                        name = "bucket_id",
                    },
                },
                is_local = false,
                sharding_key = { "id" },
            },
            adg_test_staging = {
                format = {
                    {
                        name = "id",
                        type = "integer",
                        is_nullable = false,
                    },
                    {
                        name = "int_col",
                        type = "integer",
                        is_nullable = false,
                    },
                    {
                        name = "sysOp",
                        type = "number",
                        is_nullable = false,
                    },
                    {
                        name = "bucket_id",
                        type = "unsigned",
                        is_nullable = true,
                    },
                },
                temporary = false,
                engine = "vinyl",
                indexes = {
                    {
                        unique = true,
                        parts = {
                            {
                                path = "id",
                                type = "integer",
                                is_nullable = false,
                            },
                            {
                                path = "int_col",
                                type = "integer",
                                is_nullable = false,
                            },
                        },
                        type = "TREE",
                        name = "id",
                    },
                    {
                        unique = false,
                        parts = {
                            {
                                path = "bucket_id",
                                type = "unsigned",
                                is_nullable = true,
                            },
                        },
                        type = "TREE",
                        name = "bucket_id",
                    },
                },
                is_local = false,
                sharding_key = { "id" },
            },
            adg_test_history = {
                format = {
                    {
                        name = "id",
                        type = "integer",
                        is_nullable = false,
                    },
                    {
                        name = "int_col",
                        type = "integer",
                        is_nullable = false,
                    },
                    {
                        name = "bucket_id",
                        type = "unsigned",
                        is_nullable = true,
                    },
                    {
                        name = "sysFrom",
                        type = "number",
                        is_nullable = false,
                    },
                    {
                        name = "sysOp",
                        type = "number",
                        is_nullable = false,
                    },
                    {
                        name = "sysTo",
                        type = "number",
                        is_nullable = false,
                    },
                },
                temporary = false,
                engine = "vinyl",
                indexes = {
                    {
                        unique = true,
                        parts = {
                            {
                                path = "id",
                                type = "integer",
                                is_nullable = false,
                            },
                            {
                                path = "int_col",
                                type = "integer",
                                is_nullable = false,
                            },
                            {
                                path = "sysFrom",
                                type = "number",
                                is_nullable = false,
                            },
                        },
                        type = "TREE",
                        name = "id",
                    },
                    {
                        unique = false,
                        parts = {
                            {
                                path = "bucket_id",
                                type = "unsigned",
                                is_nullable = true,
                            },
                        },
                        type = "TREE",
                        name = "bucket_id",
                    },
                },
                is_local = false,
                sharding_key = { "id" },
            },
        },
    }, {
        status = 200,
    })
    ---- Загрузить данные
    assert_http_json_request("POST", "/api/v1/kafka/subscription", {
        topicName = "adg_test",
        spaceNames = { "adg_test_staging" },
        avroSchema = nil,
        maxNumberOfMessagesPerPartition = 100,
        maxIdleSecondsBeforeCbCall = 100,
        callbackFunction = {
            callbackFunctionName = "transfer_data_to_scd_table_on_cluster_cb",
            callbackFunctionParams = {
                _space = "adg_test_staging",
                _stage_data_table_name = "adg_test_staging",
                _actual_data_table_name = "adg_test_actual",
                _historical_data_table_name = "adg_test_history",
                _delta_number = 40,
            },
        },
    }, {
        status = 200,
    })
    fiber.sleep(5)

    local _, decoded_value = bin_avro_utils.encode(value_schema, { { 1, 1, 0 }, { 1, 5, 0 } }, true)
    producer:produce({ topic = "adg_test", key = "test_key", value = decoded_value })
    fiber.sleep(3)

    assert_http_json_request(
        "GET",
        -- luacheck: max line length 210
        "/api/etl/transfer_data_to_scd_table?_stage_data_table_name=adg_test_staging&_actual_data_table_name=adg_test_actual&_historical_data_table_name=adg_test_history&_delta_number=2",
        nil,
        { status = 200 }
    )
    fiber.sleep(1)

    -- bucket_id назначен корректно в соответствии с ключом шардирования 1
    local r = storage1:eval("return box.space.adg_test_actual:select{}")
    t.assert_equals(r[1][5], r[2][5])

    -- Удалить спейс (/api/v1/ddl/table/queuedDelete/prefix/:tablePrefix)
    assert_http_json_request("DELETE", "/api/v1/ddl/table/queuedDelete/prefix/adg_tes", nil, { status = 200 })
    fiber.sleep(1)

    -- Создать спейс с именем 1, ключом шардирования 2
    assert_http_json_request("POST", "/api/v1/ddl/table/queuedCreate", {
        spaces = {
            adg_test_actual = {
                format = {
                    {
                        name = "id",
                        type = "integer",
                        is_nullable = false,
                    },
                    {
                        name = "int_col",
                        type = "integer",
                        is_nullable = false,
                    },
                    {
                        name = "sysFrom",
                        type = "number",
                        is_nullable = false,
                    },
                    {
                        name = "sysOp",
                        type = "number",
                        is_nullable = false,
                    },
                    {
                        name = "bucket_id",
                        type = "unsigned",
                        is_nullable = true,
                    },
                },
                temporary = false,
                engine = "vinyl",
                indexes = {
                    {
                        unique = true,
                        parts = {
                            {
                                path = "id",
                                type = "integer",
                                is_nullable = false,
                            },
                            {
                                path = "int_col",
                                type = "integer",
                                is_nullable = false,
                            },
                            {
                                path = "sysFrom",
                                type = "number",
                                is_nullable = false,
                            },
                        },
                        type = "TREE",
                        name = "id",
                    },
                    {
                        unique = false,
                        parts = {
                            {
                                path = "bucket_id",
                                type = "unsigned",
                                is_nullable = true,
                            },
                        },
                        type = "TREE",
                        name = "bucket_id",
                    },
                },
                is_local = false,
                sharding_key = { "int_col" },
            },
            adg_test_staging = {
                format = {
                    {
                        name = "id",
                        type = "integer",
                        is_nullable = false,
                    },
                    {
                        name = "int_col",
                        type = "integer",
                        is_nullable = false,
                    },
                    {
                        name = "sysOp",
                        type = "number",
                        is_nullable = false,
                    },
                    {
                        name = "bucket_id",
                        type = "unsigned",
                        is_nullable = true,
                    },
                },
                temporary = false,
                engine = "vinyl",
                indexes = {
                    {
                        unique = true,
                        parts = {
                            {
                                path = "id",
                                type = "integer",
                                is_nullable = false,
                            },
                            {
                                path = "int_col",
                                type = "integer",
                                is_nullable = false,
                            },
                        },
                        type = "TREE",
                        name = "id",
                    },
                    {
                        unique = false,
                        parts = {
                            {
                                path = "bucket_id",
                                type = "unsigned",
                                is_nullable = true,
                            },
                        },
                        type = "TREE",
                        name = "bucket_id",
                    },
                },
                is_local = false,
                sharding_key = { "int_col" },
            },
            adg_test_history = {
                format = {
                    {
                        name = "id",
                        type = "integer",
                        is_nullable = false,
                    },
                    {
                        name = "int_col",
                        type = "integer",
                        is_nullable = false,
                    },
                    {
                        name = "bucket_id",
                        type = "unsigned",
                        is_nullable = true,
                    },
                    {
                        name = "sysFrom",
                        type = "number",
                        is_nullable = false,
                    },
                    {
                        name = "sysOp",
                        type = "number",
                        is_nullable = false,
                    },
                    {
                        name = "sysTo",
                        type = "number",
                        is_nullable = false,
                    },
                },
                temporary = false,
                engine = "vinyl",
                indexes = {
                    {
                        unique = true,
                        parts = {
                            {
                                path = "id",
                                type = "integer",
                                is_nullable = false,
                            },
                            {
                                path = "int_col",
                                type = "integer",
                                is_nullable = false,
                            },
                            {
                                path = "sysFrom",
                                type = "number",
                                is_nullable = false,
                            },
                        },
                        type = "TREE",
                        name = "id",
                    },
                    {
                        unique = false,
                        parts = {
                            {
                                path = "bucket_id",
                                type = "unsigned",
                                is_nullable = true,
                            },
                        },
                        type = "TREE",
                        name = "bucket_id",
                    },
                },
                is_local = false,
                sharding_key = { "int_col" },
            },
        },
    }, {
        status = 200,
    })
    -- Загрузить данные
    assert_http_json_request("POST", "/api/v1/kafka/subscription", {
        topicName = "adg_test",
        spaceNames = { "adg_test_staging" },
        avroSchema = nil,
        maxNumberOfMessagesPerPartition = 100,
        maxIdleSecondsBeforeCbCall = 100,
        callbackFunction = {
            callbackFunctionName = "transfer_data_to_scd_table_on_cluster_cb",
            callbackFunctionParams = {
                _space = "adg_test_staging",
                _stage_data_table_name = "adg_test_staging",
                _actual_data_table_name = "adg_test_actual",
                _historical_data_table_name = "adg_test_history",
                _delta_number = 40,
            },
        },
    }, {
        status = 200,
    })
    fiber.sleep(5)

    _, decoded_value = bin_avro_utils.encode(value_schema, { { 1, 1, 0 }, { 1, 5, 0 } }, true)
    producer:produce({ topic = "adg_test", key = "test_key", value = decoded_value })
    fiber.sleep(3)

    assert_http_json_request(
        "GET",
        -- luacheck: max line length 210
        "/api/etl/transfer_data_to_scd_table?_stage_data_table_name=adg_test_staging&_actual_data_table_name=adg_test_actual&_historical_data_table_name=adg_test_history&_delta_number=2",
        nil,
        { status = 200 }
    )
    fiber.sleep(3)

    -- Ожидание: bucket_id загруженных записей назначен в соответствии с ключом шардирования 2
    -- Реальность: bucket_id загруженных записей назначен в соответствии с ключом шардирования 1
    r = storage1:eval("return box.space.adg_test_actual:select{}")
    t.assert_not_equals(r[1][5], r[2][5])
end
