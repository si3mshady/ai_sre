import json
import logging
import time

from pyflink.datastream import StreamExecutionEnvironment
from pyflink.datastream.connectors.kafka import FlinkKafkaConsumer, FlinkKafkaProducer
from pyflink.common.serialization import SimpleStringSchema
from pyflink.common.typeinfo import Types
from pyflink.datastream.window import TumblingEventTimeWindows
from pyflink.common.time import Time, Duration
from pyflink.common.watermark_strategy import WatermarkStrategy, TimestampAssigner

# Define the Assigner Class correctly
class OrderTimestampAssigner(TimestampAssigner):
    def extract_timestamp(self, value, record_timestamp):
        try:
            o = json.loads(value)
            # Flink expects milliseconds
            return int(o.get("timestamp", 0) * 1000)
        except Exception:
            return 0

def parse_order(event_json):
    try:
        return json.loads(event_json)
    except Exception:
        return None

def compute_slo_metrics(orders):
    if not orders:
        return None

    prep_times = [o.get('prep_time_required', 0) for o in orders if o.get('prep_time_required') is not None]
    if not prep_times:
        return None

    avg_prep = sum(prep_times) / len(prep_times)
    sorted_pts = sorted(prep_times)
    idx = int(0.95 * (len(sorted_pts) - 1))
    p95_prep = sorted_pts[idx]

    # Use first order for metadata
    first = orders[0]
    
    return {
        'tenant_id': first.get('tenant_id'),
        'station': first.get('station'),
        'window_start': first.get('timestamp'),
        'avg_prep_time': round(avg_prep, 2),
        'p95_prep_time': round(p95_prep, 2),
        'order_count': len(orders),
        'alert_type': 'SLO_VIOLATION' if avg_prep > 10 or p95_prep > 14 or len(orders) > 8 else 'NORMAL',
        'severity': 'CRITICAL' if avg_prep > 12 or p95_prep > 16 else 'WARNING',
        'processed_at': time.time(),
    }

def main():
    env = StreamExecutionEnvironment.get_execution_environment()
    env.set_parallelism(1)

    kafka_props = {
        "bootstrap.servers": "redpanda:9092",
        "group.id": "flink-slo-monitor",
    }

    consumer = FlinkKafkaConsumer(
        topics=['t1_kitchen.orders'],
        deserialization_schema=SimpleStringSchema(),
        properties=kafka_props
    )
    consumer.set_start_from_latest()

    stream = env.add_source(consumer)

    # ✅ FIX: Use the class instance instead of a function
    watermark_strategy = (
        WatermarkStrategy
        .for_bounded_out_of_orderness(Duration.of_seconds(20))
        .with_timestamp_assigner(OrderTimestampAssigner())
    )

    # Applying the strategy and keying
    keyed_stream = (
        stream
        .assign_timestamps_and_watermarks(watermark_strategy)
        .map(lambda x: parse_order(x), output_type=Types.PICKLED_BYTE_ARRAY())
        .filter(lambda x: x is not None)
        .key_by(lambda x: x.get('station', 'unknown'))
    )

    # Simplified Window Logic
    windowed_stream = (
        keyed_stream.window(TumblingEventTimeWindows.of(Time.seconds(60)))
        .reduce(lambda a, b: a + [b] if isinstance(a, list) else [a, b])
    )

    alert_stream = (
        windowed_stream
        .map(lambda orders: compute_slo_metrics(orders if isinstance(orders, list) else [orders]))
        .filter(lambda x: x is not None)
        .map(lambda x: json.dumps(x), output_type=Types.STRING())
    )

    producer = FlinkKafkaProducer(
        topic='t1_kitchen.alerts',
        serialization_schema=SimpleStringSchema(),
        producer_config={"bootstrap.servers": "redpanda:9092"}
    )

    alert_stream.add_sink(producer)
    env.execute("Elite Ghost Kitchen SLO Monitor")

if __name__ == "__main__":
    main()
