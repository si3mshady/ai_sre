import json
import logging
import time

from pyflink.datastream import StreamExecutionEnvironment, TimeCharacteristic
from pyflink.datastream.connectors.kafka import FlinkKafkaConsumer, FlinkKafkaProducer
from pyflink.common.serialization import SimpleStringSchema
from pyflink.common.typeinfo import Types
from pyflink.datastream.window import TumblingEventTimeWindows
from pyflink.common.time import Time
from pyflink.common.watermark_strategy import WatermarkStrategy

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

def parse_order(event_json):
    try:
        return json.loads(event_json)
    except Exception:
        return None

def extract_event_timestamp(event_json, _):
    o = parse_order(event_json)
    if not o:
        return 0
    # event timestamp is in seconds; convert to ms
    return int(o.get("timestamp", 0) * 1000)

def compute_slo_metrics(orders):
    if not orders:
        return None

    prep_times = [o.get('prep_time_required', 0) for o in orders]
    prep_times = [p for p in prep_times if p is not None]

    if not prep_times:
        return None

    avg_prep = sum(prep_times) / len(prep_times)
    sorted_pts = sorted(prep_times)
    idx = int(0.95 * (len(sorted_pts) - 1))
    p95_prep = sorted_pts[idx]

    station = orders[0].get('station')
    tenant = orders[0].get('tenant_id')
    window_start = orders[0].get('timestamp')

    alert = {
        'tenant_id': tenant,
        'station': station,
        'window_start': window_start,
        'avg_prep_time': avg_prep,
        'p95_prep_time': p95_prep,
        'order_count': len(orders),
        'alert_type': 'SLO_VIOLATION' if avg_prep > 10 or p95_prep > 14 or len(orders) > 8 else 'NORMAL',
        'severity': 'CRITICAL' if avg_prep > 12 or p95_prep > 16 else 'WARNING',
        # keep a processing-time timestamp too, but not for watermarks
        'processed_at': time.time(),
    }
    return alert

def main():
    env = StreamExecutionEnvironment.get_execution_environment()
    env.set_parallelism(1)
    env.set_stream_time_characteristic(TimeCharacteristic.EventTime)

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

    watermark_strategy = (
        WatermarkStrategy
        .for_bounded_out_of_orderness(Time.seconds(20))
        .with_timestamp_assigner(extract_event_timestamp)
    )

    # Station-keyed, event-time windows
    keyed_stream = (
        stream
        .assign_timestamps_and_watermarks(watermark_strategy)
        .key_by(lambda x: (parse_order(x) or {}).get('station', 'unknown'))
    )

    # Aggregate into list of orders per window
    def create_accumulator():
        return []

    def add(value, accumulator):
        o = parse_order(value)
        if o:
            accumulator.append(o)
        return accumulator

    def get_result(accumulator):
        return accumulator

    windowed_stream = keyed_stream.window(
        TumblingEventTimeWindows.of(Time.seconds(60))
    ).aggregate(
        add_function=add,
        create_accumulator=create_accumulator,
        get_result=get_result,
        accumulator_type=Types.PICKLED_BYTE_ARRAY(),
        result_type=Types.PICKLED_BYTE_ARRAY(),
    )

    alert_stream = (
        windowed_stream
        .map(
            lambda orders: json.dumps(compute_slo_metrics(orders)) if compute_slo_metrics(orders) else "",
            output_type=Types.STRING()
        )
        .filter(lambda x: x != "")
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
