import json
from pyflink.datastream import StreamExecutionEnvironment
from pyflink.datastream.connectors.kafka import FlinkKafkaConsumer, FlinkKafkaProducer
from pyflink.common.serialization import SimpleStringSchema
from pyflink.common.typeinfo import Types

def monitor_load(event_json: str):
    try:
        event = json.loads(event_json)
        if event.get("prep_time_required", 0) > 12:
            alert = {
                "alert_type": "STATION_OVERLOAD",
                "station": event.get("station"),
                "reason": f"High load: {event['item']} requires {event['prep_time_required']}m",
                "timestamp": event.get("timestamp"),
            }
            return json.dumps(alert)
    except Exception:
        pass
    return None

def main():
    env = StreamExecutionEnvironment.get_execution_environment()
    env.set_parallelism(1)

    kafka_props = {
        "bootstrap.servers": "redpanda:9092",
        "group.id": "flink-monitor",
    }

    consumer = FlinkKafkaConsumer(
        "kitchen.orders",
        SimpleStringSchema(),
        kafka_props,
    )
    consumer.set_start_from_latest()

    stream = env.add_source(consumer)

    alert_stream = (
        stream
        .map(monitor_load, output_type=Types.STRING())
        .filter(lambda x: x is not None)
    )

    producer = FlinkKafkaProducer(
        topic="kitchen.alerts",
        serialization_schema=SimpleStringSchema(),
        producer_config={"bootstrap.servers": "redpanda:9092"},
    )

    alert_stream.add_sink(producer)
    env.execute("Ghost Kitchen Monitor")

if __name__ == "__main__":
    main()
