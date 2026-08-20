close all
clear all

objects = imaqfind; %find video input objects in memory
delete(objects);

% POS
% Q_N=32;
% Cmean=zeros(3,Q_N);
% Smean=zeros(2,Q_N);
% Sstd=zeros(2,Q_N);
% hmean=zeros(1,Q_N);
% H=0;

% POS
Cmean=[];
Smean=[];
Svar=[];
hmean=[];
H=0;
lambda1=0.99;   % 0.95~0.99
lambda2=0.9;    % 0.9

%% setup
% Create the face detector object.
faceDetector = vision.CascadeObjectDetector();

% Create the point tracker object.
pointTracker = vision.PointTracker('MaxBidirectionalError', 2);

% Create the webcam object.
cam = webcam();
cam.Resolution='1280x720';%'1920x1080';

% Capture one frame to get its size.
videoFrame = snapshot(cam);
frameSize = size(videoFrame);

% Create the video player object.
videoPlayer = vision.VideoPlayer('Position', [0 0 [frameSize(2), frameSize(1)]]);

%% tracking
runLoop = true;
numPts = 0;
frameCount = 0;

tic
while runLoop && frameCount < 30*30

    % Get the next frame.
    videoFrame = snapshot(cam);
    videoFrameGray = im2gray(videoFrame);
    frameCount = frameCount + 1;

    if numPts < 10
        % Detection mode.
        bbox = faceDetector.step(videoFrameGray);

        if ~isempty(bbox)
            % Find corner points inside the detected region.
            points = detectMinEigenFeatures(videoFrameGray, 'ROI', bbox(1, :));

            % Re-initialize the point tracker.
            xyPoints = points.Location;
            numPts = size(xyPoints,1);
            release(pointTracker);
            initialize(pointTracker, xyPoints, videoFrameGray);

            % Save a copy of the points.
            oldPoints = xyPoints;

            % Convert the rectangle represented as [x, y, w, h] into an
            % M-by-2 matrix of [x,y] coordinates of the four corners. This
            % is needed to be able to transform the bounding box to display
            % the orientation of the face.
            bboxPoints = bbox2points(bbox(1, :));

            % Convert the box corners into the [x1 y1 x2 y2 x3 y3 x4 y4]
            % format required by insertShape.
            bboxPolygon = reshape(bboxPoints', 1, []);

            % Display a bounding box around the detected face.
            videoFrame = insertShape(videoFrame, 'Polygon', bboxPolygon, 'LineWidth', 3);

            % Display detected corners.
            videoFrame = insertMarker(videoFrame, xyPoints, '+', 'MarkerColor', 'white');
        end

    else
        % Tracking mode.
        [xyPoints, isFound] = step(pointTracker, videoFrameGray);
        visiblePoints = xyPoints(isFound, :);
        oldInliers = oldPoints(isFound, :);

        numPts = size(visiblePoints, 1);

        if numPts >= 10
            % Estimate the geometric transformation between the old points
            % and the new points.
            [xform, inlierIdx] = estgeotform2d(...
                oldInliers, visiblePoints, 'similarity', 'MaxDistance', 4);
            oldInliers    = oldInliers(inlierIdx, :);
            visiblePoints = visiblePoints(inlierIdx, :);

            % Apply the transformation to the bounding box.
            bboxPoints = transformPointsForward(xform, bboxPoints);

            % Convert the box corners into the [x1 y1 x2 y2 x3 y3 x4 y4]
            % format required by insertShape.
            bboxPolygon = reshape(bboxPoints', 1, []);

            % faceimg extraction
            theta=atan((bboxPoints(2,2)-bboxPoints(1,2))/(bboxPoints(2,1)-bboxPoints(1,1)));
            rot_Mtx1=[[cos(theta) -sin(theta)];[sin(theta) cos(theta)]];
            rot_Mtx2=[rot_Mtx1,[0;0]; 0 0 1];
            tform = affine2d(rot_Mtx2);
            videoFrame2 = imwarp(videoFrame,tform);

            [MM,NN,~]=size(videoFrame);

            if tan(theta)*NN > 0
                bboxPoints2= [sin(theta)*NN; 0]+rot_Mtx1*fliplr(bboxPoints)';
            else
                bboxPoints2= [0; -sin(theta)*MM]+rot_Mtx1*fliplr(bboxPoints)';
            end

            faceimg=videoFrame2(round(bboxPoints2(1,1)):round(bboxPoints2(1,3)),round(bboxPoints2(2,1)):round(bboxPoints2(2,3)),:);
            % imshow(videoFrame2)
            % imshow(faceimg)

% motion(frameCount,:)=mean(bboxPoints);        % 움직임 1:x축, 2:y축, y축 호흡 신호로 활용

            %% POS algorithm
            % spatial average
            C(1:3,1)=mean(mean(faceimg));

            % temporal normalization
            if isempty(Cmean)
                Cmean=C;
            else
                Cmean=lambda1*Cmean+(1-lambda1)*C;
            end

            % projection
            S=[0 1 -1;-2 1 1]*(C./Cmean);
            
            % tunning
            if isempty(Smean)
                Smean=S;
            else
                Smean=lambda1*Smean+(1-lambda1)*S;
            end

            if isempty(Svar)
                Svar=(S-Smean).^2;
            else
                Svar=lambda1*Svar+(1-lambda1)*(S-Smean).^2;
            end
            Sstd=sqrt(Svar);

            % h=S(1)+Sstd(1)/(Sstd(2)+1.0000e-09)*S(2);
            h=S(1)/(Sstd(1)+1.0000e-09)+1/(Sstd(2)+1.0000e-09)*S(2);
            
            % overlap-adding
            if isempty(hmean)
                hmean=h;
            else
                hmean=lambda2*hmean+(1-lambda2)*h;
            end
            H(frameCount)=H(frameCount-1)+(h-hmean);

            plot(H)

            % Display a bounding box around the face being tracked.
            videoFrame = insertShape(videoFrame, 'Polygon', bboxPolygon, 'LineWidth', 3);

            % Display tracked points.
            videoFrame = insertMarker(videoFrame, visiblePoints, '+', 'MarkerColor', 'white');

            % Reset the points.
            oldPoints = visiblePoints;
            setPoints(pointTracker, oldPoints);
        end

    end

    % Display the annotated video frame using the video player object.
    step(videoPlayer, videoFrame);

    % Check whether the video player window has been closed.
    runLoop = isOpen(videoPlayer);
end
toc

% Clean up.
clear cam;
release(videoPlayer);
release(pointTracker);
release(faceDetector);