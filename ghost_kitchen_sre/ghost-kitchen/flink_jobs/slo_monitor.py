import json
import time
from pyflink.datastream import StreamExecutionEnvironment
from pyflink.datastream.connectors.kafka import FlinkKafkaConsumer, FlinkKafkaProducer
from pyflink.common.serialization import SimpleStringSchema
from pyflink.common.typeinfo import Types
from pyflink.datastream.window import TumblingEventTimeWindows
from pyflink.common.time import Time, Duration
from pyflink.common.watermark_strategy import WatermarkStrategy, TimestampAssigner

class OrderTimestampAssigner(TimestampAssigner):
    def extract_timestamp(self, value, record_timestamp):
        return int(json.loads(value).get("timestamp", 0) * 1000)

def compute_slo_metrics(orders):
    if not orders: return None
    pts = [o.get('prep_time_required', 0) for o in orders]
    avg_p = sum(pts) / len(pts)
    return {
        'station': orders[0].get('station'),
        'avg_prep_time': round(avg_p, 2),
        'p95_prep_time': round(sorted(pts)[int(0.95*(len(pts)-1))], 2),
        'order_count': len(orders),
        'alert_type': 'SLO_VIOLATION' if avg_p > 10 else 'NORMAL',
        'timestamp': time.time()
    }

def main():
    env = StreamExecutionEnvironment.get_execution_environment()
    kafka_props = {"bootstrap.servers": "redpanda:9092", "group.id": "flink-slo-v2"}
    consumer = FlinkKafkaConsumer(['t1_kitchen.orders'], SimpleStringSchema(), kafka_props)
    
    watermark_strategy = WatermarkStrategy.for_bounded_out_of_orderness(Duration.of_seconds(5)).with_timestamp_assigner(OrderTimestampAssigner())

    stream = env.add_source(consumer).assign_timestamps_and_watermarks(watermark_strategy)
    
    alert_stream = (
        stream.map(lambda x: json.loads(x), output_type=Types.PICKLED_BYTE_ARRAY())
        .key_by(lambda x: x.get('station'))
        .window(TumblingEventTimeWindows.of(Time.seconds(60)))
        .reduce(lambda a, b: a + [b] if isinstance(a, list) else [a, b])
        .map(lambda orders: compute_slo_metrics(orders if isinstance(orders, list) else [orders]))
        .filter(lambda x: x is not None and x['alert_type'] == 'SLO_VIOLATION')
        .map(lambda x: json.dumps(x), output_type=Types.STRING())
    )

    producer = FlinkKafkaProducer('t1_kitchen.alerts', SimpleStringSchema(), {"bootstrap.servers": "redpanda:9092"})
    alert_stream.add_sink(producer)
    env.execute("Elite Ghost Kitchen SLO Monitor")

if __name__ == "__main__":
    main()
