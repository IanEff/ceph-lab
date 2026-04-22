import json
import subprocess
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

class CephLatencyExporter(BaseHTTPRequestHandler):
    def get_osd_histograms(self):
        try:
            # Get list of all OSDs
            osd_list_cmd = ["ceph", "osd", "ls"]
            osds = subprocess.check_output(osd_list_cmd).decode('utf-8').strip().split('\n')
            
            metrics = []
            for osd_id in osds:
                try:
                    # Dump histogram for each OSD
                    perf_cmd = ["ceph", "tell", f"osd.{osd_id}", "perf", "histogram", "dump"]
                    raw_data = subprocess.check_output(perf_cmd).decode('utf-8')
                    data = json.loads(raw_data)
                    
                    # Extract read/write histograms
                    osd_data = data.get("osd", {})
                    
                    for op_type in ["r", "w"]:
                        key = f"op_{op_type}_latency_out_bytes_histogram" if op_type == "r" else f"op_{op_type}_latency_in_bytes_histogram"
                        hist = osd_data.get(key)
                        if not hist:
                            continue
                        
                        # Axis 0 is Latency (usec), Axis 1 is Size (bytes)
                        # We aggregate across Axis 1 to get a 1D latency histogram
                        latency_axis = hist["axes"][0]
                        values_2d = hist["values"]
                        
                        buckets = []
                        cumulative_count = 0
                        
                        for i, range_info in enumerate(latency_axis["ranges"]):
                            bucket_count = sum(values_2d[i])
                            cumulative_count += bucket_count
                            
                            # 'le' is the upper bound in seconds
                            if "max" in range_info and range_info["max"] != -1:
                                le = float(range_info["max"]) / 1_000_000.0
                                buckets.append((le, cumulative_count))
                        
                        # Ensure +Inf is the last bucket and reflects the final cumulative count
                        buckets.append(("+Inf", cumulative_count))
                        
                        # 1. Native metrics (used by prototype-observability dashboard)
                        metric_name_native = f"ceph_native_osd_op_{op_type}_latency_seconds_bucket"
                        count_name_native = f"ceph_native_osd_op_{op_type}_latency_seconds_count"
                        
                        # 2. Standard-ish metrics (used by elk-slo-dashboard rules)
                        metric_name_std = f"ceph_osd_op_{op_type}_latency_bucket"
                        count_name_std = f"ceph_osd_op_{op_type}_latency_count"
                        
                        for le, count in buckets:
                            metrics.append(f'{metric_name_native}{{osd="osd.{osd_id}",le="{le}"}} {count}')
                            metrics.append(f'{metric_name_std}{{osd="osd.{osd_id}",le="{le}"}} {count}')
                        
                        metrics.append(f'{count_name_native}{{osd="osd.{osd_id}"}} {cumulative_count}')
                        metrics.append(f'{count_name_std}{{osd="osd.{osd_id}"}} {cumulative_count}')
                
                except Exception as e:
                    print(f"Error scraping OSD {osd_id}: {e}")
            
            return "\n".join(metrics)
        except Exception as e:
            print(f"Global error: {e}")
            return ""

    def do_GET(self):
        if self.path == "/metrics":
            self.send_response(200)
            self.send_header("Content-type", "text/plain")
            self.end_headers()
            self.wfile.write(self.get_osd_histograms().encode('utf-8'))
        else:
            self.send_response(404)
            self.end_headers()

if __name__ == "__main__":
    server = HTTPServer(("0.0.0.0", 8080), CephLatencyExporter)
    print("Ceph Latency Exporter started on port 8080")
    server.serve_forever()
