from pyflink.datastream import StreamExecutionEnvironment
from pyflink.datastream.connectors.kafka import FlinkKafkaConsumer, FlinkKafkaProducer
from pyflink.common.serialization import SimpleStringSchema
from pyflink.common.typeinfo import Types
import json


def enrich_event(event):

    risk_score = {"low": 1, "medium": 3, "high": 5}.get(event.get("risk_level"), 1)

    correlation_flag = False
    if event.get("risk_level") == "high" and event.get("previous_zone") == event.get("zone"):
        correlation_flag = True

    event["safety_score"] = risk_score
    event["suspicious_activity"] = correlation_flag

    return json.dumps(event)


env = StreamExecutionEnvironment.get_execution_environment()
env.set_parallelism(1)


kafka_props = {
    "bootstrap.servers": "redpanda:9092",
    "group.id": "flink-enricher"
}


consumer = FlinkKafkaConsumer(
    topics="construction.events",
    deserialization_schema=SimpleStringSchema(),
    properties=kafka_props
)

# IMPORTANT
consumer.set_start_from_earliest()


producer = FlinkKafkaProducer(
    topic="construction.enriched",
    serialization_schema=SimpleStringSchema(),
    producer_config={"bootstrap.servers": "redpanda:9092"}
)


stream = env.add_source(consumer)


enriched_stream = stream.map(
    lambda x: enrich_event(json.loads(x)),
    output_type=Types.STRING()
)


enriched_stream.add_sink(producer)


env.execute("Construction Enrichment Stream")
