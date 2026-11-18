# ONNX 모델을 OpenVINO IR로 변환하고 그래프 확인하기

[변환 코드](convert_onnx.py)는 OpenVINO로 ONNX 모델을 읽고 원래 입력 형태를 유지한 채 XML과 BIN 파일을 저장한다. [그래프 확인 코드](inspect_ir.py)는 IR을 다시 열어 각 노드의 이름, 연산 종류와 출력 형태를 출력한다.

## 실행

Python 3.12와 OpenVINO 2025.0에서 확인했다. 작업 폴더에 `model/test.onnx`를 준비한 뒤 두 스크립트를 순서대로 실행한다.

```sh
python -m pip install openvino==2025.0.0
python convert_onnx.py
python inspect_ir.py
```

첫 번째 스크립트는 `ir_output/model.xml`과 `ir_output/model.bin`을 만든다. 로컬 ONNX 파일 한 개로 변환과 재로딩을 확인하고, 원본과 IR의 입력·출력 형태가 일치하는지 비교했다. 모델의 추론값을 비교하는 시험은 수행하지 않았다. 원본 모델과 변환된 가중치는 별도로 준비한다.
