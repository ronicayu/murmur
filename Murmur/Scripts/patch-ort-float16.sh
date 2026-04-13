#!/bin/bash
# Patches the ORT ObjC wrapper to support Float16 tensor element type.
# Must run after `swift package resolve` and before `swift build`.
# Safe to run multiple times (idempotent).

set -e

ORT_DIR=".build/checkouts/onnxruntime-swift-package-manager/objectivec"
ENUMS_H="$ORT_DIR/include/ort_enums.h"
ENUMS_MM="$ORT_DIR/ort_enums.mm"

if [ ! -f "$ENUMS_H" ]; then
    echo "ORT not resolved yet. Run: swift package resolve"
    exit 1
fi

# Patch ort_enums.h — add Float16 to enum
if ! grep -q "Float16" "$ENUMS_H"; then
    sed -i '' 's/ORTTensorElementDataTypeString,/ORTTensorElementDataTypeString,\
  ORTTensorElementDataTypeFloat16,/' "$ENUMS_H"
    echo "Patched $ENUMS_H"
else
    echo "$ENUMS_H already patched"
fi

# Patch ort_enums.mm — add Float16 mapping
if ! grep -q "Float16" "$ENUMS_MM"; then
    sed -i '' 's/{ORTTensorElementDataTypeString, ONNX_TENSOR_ELEMENT_DATA_TYPE_STRING, std::nullopt},/{ORTTensorElementDataTypeString, ONNX_TENSOR_ELEMENT_DATA_TYPE_STRING, std::nullopt},\
    {ORTTensorElementDataTypeFloat16, ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT16, sizeof(uint16_t)},/' "$ENUMS_MM"
    echo "Patched $ENUMS_MM"
else
    echo "$ENUMS_MM already patched"
fi
