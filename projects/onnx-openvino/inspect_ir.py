import openvino as ov

def print_ir_full_graph(xml_path):
    core = ov.Core()
    model = core.read_model(xml_path)
    
    print("IR 모델의 전체 노드 정보:")
    for op in model.get_ops():
        try:
            shape = op.output(0).get_partial_shape()
        except Exception:
            shape = "N/A"
        print(f"  {op.get_friendly_name():30s} {op.get_type_name():20s} 출력 shape: {shape}")

if __name__ == "__main__":
    xml_path = "./ir_output/model.xml"
    print_ir_full_graph(xml_path)
