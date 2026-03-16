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

# --- STABLE ASSIGNER ---
class OrderTimestampAssigner(TimestampAssigner):
    def extract_timestamp(self, value, record_timestamp):
        try:
            o = json.loads(value)
            return int(o.get("timestamp", 0) * 1000)
        except Exception:
            return 0

def parse_order(event_json):
    try:
        return json.loads(event_json)
    except Exception:
        return None

# --- STABLE METRICS LOGIC ---
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

    first = orders[0]
    
    # Keeping all original keys so your Dashboard and Agent don't break
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

    # Internal K3s address for Redpanda
    brokers = "redpanda-0.redpanda.kitchen-sre.svc.cluster.local:9092"

    kafka_props = {
        "bootstrap.servers": brokers,
        "group.id": "flink-slo-monitor-stable",
    }

    consumer = FlinkKafkaConsumer(
        topics=['t1_kitchen.orders'],
        deserialization_schema=SimpleStringSchema(),
        properties=kafka_props
    )
    consumer.set_start_from_latest()

    watermark_strategy = (
        WatermarkStrategy
        .for_bounded_out_of_orderness(Duration.of_seconds(20))
        .with_timestamp_assigner(OrderTimestampAssigner())
    )

    # STABLE PIPELINE: Using PICKLED_BYTE_ARRAY for flexible reduction
    ds = env.add_source(consumer)
    
    alert_stream = (
        ds.assign_timestamps_and_watermarks(watermark_strategy)
        .map(lambda x: parse_order(x), output_type=Types.PICKLED_BYTE_ARRAY())
        .filter(lambda x: x is not None)
        .key_by(lambda x: x.get('station', 'unknown'))
        .window(TumblingEventTimeWindows.of(Time.seconds(60)))
        .reduce(lambda a, b: a + [b] if isinstance(a, list) else [a, b])
        .map(lambda orders: compute_slo_metrics(orders if isinstance(orders, list) else [orders]))
        .filter(lambda x: x is not None)
        .map(lambda x: json.dumps(x), output_type=Types.STRING())
    )

    producer = FlinkKafkaProducer(
        topic='t1_kitchen.alerts',
        serialization_schema=SimpleStringSchema(),
        producer_config={"bootstrap.servers": brokers}
    )

    alert_stream.add_sink(producer)
    
    print("🚀 Flink SLO Monitor (Stable Version) starting...")
    env.execute("Elite Ghost Kitchen SLO Monitor")

if __name__ == "__main__":
    main()
