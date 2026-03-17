import json, logging, time, math
from pyflink.datastream import StreamExecutionEnvironment
from pyflink.datastream.connectors.kafka import FlinkKafkaConsumer, FlinkKafkaProducer
from pyflink.common.serialization import SimpleStringSchema
from pyflink.common.typeinfo import Types
from pyflink.datastream.window import TumblingEventTimeWindows
from pyflink.common.time import Time, Duration
from pyflink.common.watermark_strategy import WatermarkStrategy
from pyflink.datastream.functions import ProcessWindowFunction

# 1. Class-based window processing to fix the 'open' attribute error
class KitchenWindowProcess(ProcessWindowFunction):
    def clear(self, context):
        pass

    def process(self, key, context, elements):
        orders = [e for e in elements]
        metrics = compute_slo_metrics(orders)
        if metrics and metrics.get('alert_type') == 'SLO_VIOLATION':
            yield json.dumps(metrics)

def compute_slo_metrics(orders):
    if not orders: return None
    prep_times = [o.get('prep_time_required', 0) for o in orders if o.get('prep_time_required') is not None]
    if not prep_times: return None

    avg_prep = sum(prep_times) / len(prep_times)
    p95_prep = sorted(prep_times)[int(0.95 * (len(prep_times) - 1))]
    order_count = len(orders)

    suggested = max(1, math.ceil(order_count / 3))
    is_violation = avg_prep > 10 or p95_prep > 14 or order_count > 8

    return {
        'tenant_id': orders[0].get('tenant_id'),
        'station': orders[0].get('station', 'unknown'),
        'avg_prep_time': round(avg_prep, 2),
        'p95_prep_time': round(p95_prep, 2),
        'order_count': order_count,
        'suggested_replicas': suggested,
        'alert_type': 'SLO_VIOLATION' if is_violation else 'NORMAL',
        'action_required': 'SCALE' if is_violation else 'NONE',
        'processed_at': time.time(),
    }

def main():
    env = StreamExecutionEnvironment.get_execution_environment()
    env.set_parallelism(1) # Recommended for local k3s testing
    
    brokers = "redpanda-0.redpanda.kitchen-sre.svc.cluster.local:9092"
    
    consumer = FlinkKafkaConsumer(
        ['t1_kitchen.orders'], 
        SimpleStringSchema(), 
        {"bootstrap.servers": brokers, "group.id": "flink-scaler"}
    )
    
    ds = env.add_source(consumer.set_start_from_latest())

    # 2. Fix the Watermark/Timer error by adding Idleness
    watermark_strategy = WatermarkStrategy \
        .for_bounded_out_of_orderness(Duration.of_seconds(20)) \
        .with_timestamp_assigner(lambda x, _: int(json.loads(x).get('timestamp', 0) * 1000)) \
        .with_idleness(Duration.of_minutes(1)) 

    alert_stream = (
        ds.assign_timestamps_and_watermarks(watermark_strategy)
        .map(lambda x: json.loads(x), output_type=Types.PICKLED_BYTE_ARRAY())
        .key_by(lambda x: x.get('station', 'unknown'))
        .window(TumblingEventTimeWindows.of(Time.seconds(60)))
        # 3. Use the ProcessWindowFunction class here
        .process(KitchenWindowProcess(), output_type=Types.STRING())
    )

    alert_stream.add_sink(FlinkKafkaProducer(
        't1_kitchen.alerts', 
        SimpleStringSchema(), 
        {"bootstrap.servers": brokers}
    ))
    
    env.execute("Elite Ghost Kitchen Scaler")

if __name__ == "__main__":
    main()
