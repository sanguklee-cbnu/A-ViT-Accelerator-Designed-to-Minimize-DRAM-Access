import os
import openvino as ov

def convert_onnx_to_ir(onnx_file, output_dir, model_name="model"):
    """
    ONNX 파일을 OpenVINO IR 파일로 변환합니다.
    
    Args:
        onnx_file (str): 변환할 ONNX 파일 경로 (예: "test.onnx")
        output_dir (str): IR 파일(.xml, .bin)을 저장할 디렉토리
        model_name (str): 생성할 IR 파일의 기본 이름 (예: "model")
    """
    # 출력 디렉토리가 없으면 생성
    os.makedirs(output_dir, exist_ok=True)
    
    # OpenVINO Core 객체 생성
    core = ov.Core()
    
    # ONNX 파일 로드 (모델의 구조와 가중치가 포함됨)
    model = core.read_model(onnx_file)
    
    # 원래 ONNX 파일에 지정된 입력 크기를 그대로 사용합니다.
    # (입력 크기를 변경하면 reshape 관련 오류가 발생할 수 있으므로 reshape()은 호출하지 않습니다.)
    
    # IR 파일 저장: ov.save_model() 호출 시, .xml과 .bin 파일 모두 생성됩니다.
    xml_path = os.path.join(output_dir, f"{model_name}.xml")
    ov.save_model(model, xml_path)
    
    print(f"IR 모델이 저장되었습니다:\n  XML: {xml_path}\n  BIN: {os.path.join(output_dir, f'{model_name}.bin')}")

if __name__ == "__main__":
    onnx_file = "./model/test.onnx"        # 변환할 ONNX 파일 경로
    output_dir = "./ir_output"      # IR 파일 저장 폴더
    convert_onnx_to_ir(onnx_file, output_dir, model_name="model")
