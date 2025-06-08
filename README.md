# Introduction

This is a dedicated iOS application for recording **RGB-D data** using the **Structure Sensor**.  

The app is extended from the official **Structure SDK Viewer** example and includes functionality for real-time synchronised RGB and Depth capture.

## 📂 Format

- rgb file: {0000}_color.png

- depth file: {0000}_depth.png

- intrinsics: depth_intrinsics.txt & rgb_intrinsics.txt

- extrinsics: extrinsics.txt
    
##  🛠️ Tutorial

- Record button (start recording)

- Stop button (stop recording)

- Finish button (blank folder to distinguish different sequences)

	- You should first push the finish button to start the real-time reveal on the start button

## 📱 Platform

- iOS (iPhone/iPad)
- Requires Structure Sensor + Structure SDK

## 📌 Features

- Real-time RGB and Depth preview and recording
- Timestamped folder creation (millisecond precision)
- Direct hardware integration with Structure Sensor
- Based on the Structure SDK Viewer sample
- Saves data in a structured format for later processing

## Recording effect 
![hi](https://github.com/user-attachments/assets/7747517b-e774-4257-a99a-1347d61d092f)

