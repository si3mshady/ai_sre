import json, logging, time, math
from pyflink.datastream import StreamExecutionEnvironment
from pyflink.datastream.connectors.kafka import FlinkKafkaConsumer, FlinkKafkaProducer
from pyflink.common.serialization import SimpleStringSchema
from pyflink.common.typeinfo import Types
from pyflink.datastream.window import SlidingEventTimeWindows # Changed to Sliding
from pyflink.common.time import Time, Duration
from pyflink.common.watermark_strategy import WatermarkStrategy
from pyflink.datastream.functions import ProcessWindowFunction

class KitchenWindowProcess(ProcessWindowFunction):
    def process(self, key, context, elements):
        orders = [json.loads(e) if isinstance(e, str) else e for e in elements]
        metrics = compute_slo_metrics(orders)
        # CRITICAL: Only yield if it's actually a VIOLATION to avoid 0.0 noise
        if metrics and metrics.get('alert_type') == 'SLO_VIOLATION':
            yield json.dumps(metrics)

def compute_slo_metrics(orders):
    if not orders: return None
    prep_times = [o.get('prep_time_required', 0) for o in orders if o.get('prep_time_required') is not None]
    if not prep_times: return None

    avg_prep = sum(prep_times) / len(prep_times)
    p95_prep = sorted(prep_times)[int(0.95 * (len(prep_times) - 1))]
    order_count = len(orders)

    # RE-ALIGNED THRESHOLDS: Match your slo_runbook.md (p95 > 8.0)
    # We lowered these so the 40s spikes trigger the RAG immediately
    is_violation = p95_prep > 8.0 or order_count > 15

    return {
        'station': orders[0].get('station', 'unknown'),
        'p95_prep': round(p95_prep, 2), # Key name matches Agent/Runbook
        'avg_prep': round(avg_prep, 2),
        'order_count': order_count,
        'alert_type': 'SLO_VIOLATION' if is_violation else 'NORMAL',
        'processed_at': time.time(),
    }

def main():
    env = StreamExecutionEnvironment.get_execution_environment()
    env.set_parallelism(1)
    
    brokers = "redpanda-0.redpanda.kitchen-sre.svc.cluster.local:9092"
    
    consumer = FlinkKafkaConsumer(
        ['t1_kitchen.orders'], 
        SimpleStringSchema(), 
        {"bootstrap.servers": brokers, "group.id": "flink-demo-aggregator"}
    )
    
    ds = env.add_source(consumer.set_start_from_latest())

    # Tightened Watermark for faster processing
    watermark_strategy = WatermarkStrategy \
        .for_bounded_out_of_orderness(Duration.of_seconds(5)) \
        .with_timestamp_assigner(lambda x, _: int(json.loads(x).get('timestamp', 0) * 1000)) \
        .with_idleness(Duration.of_seconds(10)) 

    alert_stream = (
        ds.assign_timestamps_and_watermarks(watermark_strategy)
        .map(lambda x: json.loads(x))
        .key_by(lambda x: x.get('station', 'unknown'))
        # 10s Window that slides every 5s. Much more aggressive.
        .window(SlidingEventTimeWindows.of(Time.seconds(10), Time.seconds(5)))
        .process(KitchenWindowProcess(), output_type=Types.STRING())
    )

    alert_stream.add_sink(FlinkKafkaProducer(
        't1_kitchen.alerts', 
        SimpleStringSchema(), 
        {"bootstrap.servers": brokers}
    ))
    
    env.execute("Elite Ghost Kitchen Demo Scaler")

if __name__ == "__main__":
    main()
