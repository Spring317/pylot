"""Implements an operator that detects obstacles using a YOLOv8 model."""

import time

import erdos
import numpy as np

from pylot.perception.detection.obstacle import Obstacle
from pylot.perception.detection.utils import (
    OBSTACLE_LABELS,
    PYLOT_BBOX_COLOR_MAP,
    BoundingBox2D,
)
from pylot.perception.messages import ObstaclesMessage


class YoloDetectionOperator(erdos.Operator):
    """Detects obstacles using a YOLOv8 model via Ultralytics.

    The operator receives frames on a camera stream, and runs a YOLO model for
    each frame.  It is a drop-in replacement for
    :py:class:`~pylot.perception.detection.detection_operator.DetectionOperator`.

    Args:
        camera_stream (:py:class:`erdos.ReadStream`): The stream on which
            camera frames are received.
        time_to_decision_stream (:py:class:`erdos.ReadStream`): Stream carrying
            time-to-decision updates.
        obstacles_stream (:py:class:`erdos.WriteStream`): Stream on which the
            operator sends
            :py:class:`~pylot.perception.messages.ObstaclesMessage` messages.
        model_path (:obj:`str`): Path to the YOLOv8 ``.pt`` weights file.
        flags (absl.flags): Object to be used to access absl flags.
    """

    def __init__(
        self,
        camera_stream: erdos.ReadStream,
        time_to_decision_stream: erdos.ReadStream,
        obstacles_stream: erdos.WriteStream,
        model_path: str,
        flags,
    ):
        camera_stream.add_callback(self.on_msg_camera_stream, [obstacles_stream])
        time_to_decision_stream.add_callback(self.on_time_to_decision_update)
        self._flags = flags
        self._logger = erdos.utils.setup_logging(
            self.config.name, self.config.log_file_name
        )
        self._obstacles_stream = obstacles_stream

        # Import here so that the rest of Pylot still works when ultralytics
        # is not installed.
        from ultralytics import YOLO

        self._model = YOLO(model_path)

        # Move model to the configured GPU.
        self._model.to("cuda:{}".format(self._flags.obstacle_detection_gpu_index))

        # {int: str} mapping provided by Ultralytics.
        self._class_names = self._model.names

        # Unique bounding box id. Incremented for each kept detection.
        self._unique_id = 0

        # Warm up the model with a dummy image.
        self._model(np.zeros((108, 192, 3), dtype="uint8"), verbose=False)

    @staticmethod
    def connect(
        camera_stream: erdos.ReadStream, time_to_decision_stream: erdos.ReadStream
    ):
        """Connects the operator to other streams.

        Args:
            camera_stream (:py:class:`erdos.ReadStream`): The stream on which
                camera frames are received.
            time_to_decision_stream (:py:class:`erdos.ReadStream`): Stream
                carrying time-to-decision updates.

        Returns:
            list: A single-element list containing the
            :py:class:`erdos.WriteStream` on which the operator sends
            :py:class:`~pylot.perception.messages.ObstaclesMessage` messages.
        """
        obstacles_stream = erdos.WriteStream()
        return [obstacles_stream]

    def destroy(self):
        self._logger.warn("destroying {}".format(self.config.name))
        # Sending top watermark because the operator is not flowing watermarks.
        self._obstacles_stream.send(
            erdos.WatermarkMessage(erdos.Timestamp(is_top=True))
        )

    def on_time_to_decision_update(self, msg: erdos.Message):
        self._logger.debug(
            "@{}: {} received ttd update {}".format(
                msg.timestamp, self.config.name, msg
            )
        )

    @erdos.profile_method()
    def on_msg_camera_stream(
        self, msg: erdos.Message, obstacles_stream: erdos.WriteStream
    ):
        """Invoked whenever a frame message is received on the stream.

        Args:
            msg (:py:class:`~pylot.perception.messages.FrameMessage`): Message
                received.
            obstacles_stream (:py:class:`erdos.WriteStream`): Stream on which
                the operator sends
                :py:class:`~pylot.perception.messages.ObstaclesMessage`
                messages.
        """
        self._logger.debug(
            "@{}: {} received message".format(msg.timestamp, self.config.name)
        )
        start_time = time.time()

        # The model expects BGR images (same convention as the TF operator).
        assert msg.frame.encoding == "BGR", "Expects BGR frames"

        results = self._model(msg.frame.frame, verbose=False)

        obstacles = []
        for box in results[0].boxes:
            conf = float(box.conf[0])
            if conf < self._flags.obstacle_detection_min_score_threshold:
                continue

            cls_idx = int(box.cls[0])
            label = self._class_names[cls_idx]

            if label not in OBSTACLE_LABELS:
                self._logger.warning(
                    "Ignoring non essential detection {}".format(label)
                )
                continue

            xmin, ymin, xmax, ymax = box.xyxy[0].tolist()
            obstacles.append(
                Obstacle(
                    BoundingBox2D(int(xmin), int(xmax), int(ymin), int(ymax)),
                    conf,
                    label,
                    id=self._unique_id,
                )
            )
            self._unique_id += 1

        self._logger.debug(
            "@{}: {} obstacles: {}".format(msg.timestamp, self.config.name, obstacles)
        )

        # Get runtime in ms.
        runtime = (time.time() - start_time) * 1000
        # Send out obstacles.
        obstacles_stream.send(ObstaclesMessage(msg.timestamp, obstacles, runtime))
        obstacles_stream.send(erdos.WatermarkMessage(msg.timestamp))

        if self._flags.log_detector_output:
            msg.frame.annotate_with_bounding_boxes(
                msg.timestamp, obstacles, None, PYLOT_BBOX_COLOR_MAP
            )
            msg.frame.save(
                msg.timestamp.coordinates[0],
                self._flags.data_path,
                "detector-{}".format(self.config.name),
            )
