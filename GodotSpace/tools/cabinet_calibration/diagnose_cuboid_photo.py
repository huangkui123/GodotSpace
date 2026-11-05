"""Inspect an ordinary photograph locally without inventing camera calibration.

Writes geometric face proposals and a labelled preview. This is not a metric
pose test: ordinary photos lack the synchronized XR poses required by the UI.
"""
import argparse
import json
from pathlib import Path

import cv2
import numpy as np

from cuboid_faces import edge_map, face_proposals
from cuboid_pose import _polygons


def diagnose(photo: Path, output: Path):
    image = cv2.imdecode(np.fromfile(photo, dtype=np.uint8), cv2.IMREAD_COLOR)
    if image is None:
        raise ValueError('Cannot decode photograph')
    scale = min(1., 1280 / max(image.shape[:2]))
    small = cv2.resize(image, None, fx=scale, fy=scale)
    gray, edges = edge_map(small)
    old = _polygons(gray, edges)
    proposals = face_proposals(small)
    report = {'image_size': [image.shape[1], image.shape[0]],
              'diagnostic_size': [small.shape[1], small.shape[0]],
              'legacy_closed_silhouette_count': len(old),
              'face_proposals': proposals, 'metric_pose_valid': False,
              'automatic_application_allowed': False,
              'note': 'Geometric proposals only; no intrinsics or synchronized XR poses supplied.'}
    output.mkdir(parents=True, exist_ok=True)
    (output / 'report.json').write_text(json.dumps(report, indent=2), encoding='utf-8')
    preview = small.copy()
    if proposals:
        cv2.polylines(preview, [np.rint(proposals[0]['pixels']).astype('int32')], True, (40, 220, 40), 3)
    cv2.rectangle(preview, (0, 0), (preview.shape[1], 64), (20, 20, 20), -1)
    cv2.putText(preview, 'Largest automatic face proposal - NOT calibrated pose', (12, 26),
                cv2.FONT_HERSHEY_SIMPLEX, .65, (255, 255, 255), 1, cv2.LINE_AA)
    cv2.putText(preview, 'Multi-view geometry must reject other panels / furniture.', (12, 52),
                cv2.FONT_HERSHEY_SIMPLEX, .65, (255, 255, 255), 1, cv2.LINE_AA)
    ok, encoded = cv2.imencode('.jpg', preview, [cv2.IMWRITE_JPEG_QUALITY, 92])
    if not ok:
        raise ValueError('Cannot encode diagnostic preview')
    encoded.tofile(output / 'face-proposal.jpg')
    return report


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('photo', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    result = diagnose(args.photo, args.output)
    print(json.dumps({'legacy_closed_silhouettes': result['legacy_closed_silhouette_count'],
                      'face_proposals': len(result['face_proposals']), 'metric_pose_valid': False}))
