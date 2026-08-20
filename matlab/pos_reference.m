function out = pos_reference(inputCsv, outputCsv, lambda1, lambda2)
% POS_REFERENCE  Verbatim reference implementation of the POS block of rPPG_test.m.
%
%   pos_reference('synthetic_C.csv', 'matlab_out.csv')
%   pos_reference(inCsv, outCsv, 0.99, 0.9)
%
% Reads the cR,cG,cB columns of a recording produced by the iOS app (or by
% tools/gen_golden.py), runs the POS algorithm on them, and writes every
% intermediate back out. Compare its rppg column against the app's own, or against
% the output of `swift run rppg-replay`.
%
% The body between the ==== markers is copied from rPPG_test.m lines 133-170 with
% only the variable plumbing changed (C comes from the CSV instead of from
% mean(mean(faceimg)), and the intermediates are stored per step). Do not "tidy" it:
% the arithmetic, including the asymmetric form of h and the (1-lambda) subtraction,
% is what the Swift side is being checked against.

    if nargin < 3, lambda1 = 0.99; end
    if nargin < 4, lambda2 = 0.9;  end

    T = readtable(inputCsv);
    Cs = [T.cR, T.cG, T.cB];
    n = size(Cs, 1);

    % POS state, exactly as initialised in rPPG_test.m
    Cmean = [];
    Smean = [];
    Svar  = [];
    hmean = [];
    H     = 0;

    cols = zeros(n, 20);

    for k = 1:n
        C = Cs(k, :)';   % 3-by-1 column, as in C(1:3,1) = mean(mean(faceimg));

        % ==================== rPPG_test.m lines 137-170 ====================
        % temporal normalization
        if isempty(Cmean)
            Cmean = C;
        else
            Cmean = lambda1*Cmean + (1-lambda1)*C;
        end

        % projection
        Cn = C./Cmean;
        S = [0 1 -1; -2 1 1]*Cn;

        % tunning
        if isempty(Smean)
            Smean = S;
        else
            Smean = lambda1*Smean + (1-lambda1)*S;
        end

        if isempty(Svar)
            Svar = (S-Smean).^2;
        else
            Svar = lambda1*Svar + (1-lambda1)*(S-Smean).^2;
        end
        Sstd = sqrt(Svar);

        h = S(1)/(Sstd(1)+1.0000e-09) + 1/(Sstd(2)+1.0000e-09)*S(2);

        % overlap-adding
        if isempty(hmean)
            hmean = h;
        else
            hmean = lambda2*hmean + (1-lambda2)*h;
        end

        if k == 1
            H(k) = 0 + (h-hmean);
        else
            H(k) = H(k-1) + (h-hmean);
        end
        % ===================================================================

        cols(k, :) = [C', Cmean', Cn', S', Smean', Svar', Sstd', h, hmean, H(k)];
    end

    names = {'cR','cG','cB','cMeanR','cMeanG','cMeanB','cNormR','cNormG','cNormB', ...
             's1','s2','sMean1','sMean2','sVar1','sVar2','sStd1','sStd2', ...
             'h','hMean','rppg'};
    out = array2table(cols, 'VariableNames', names);

    if nargin >= 2 && ~isempty(outputCsv)
        % 17 significant digits so the file round-trips a double exactly.
        writetable(out, outputCsv, 'Delimiter', ',');
        fid = fopen(outputCsv, 'w');
        fprintf(fid, '%s\n', strjoin(names, ','));
        for k = 1:n
            fprintf(fid, '%.17g', cols(k, 1));
            fprintf(fid, ',%.17g', cols(k, 2:end));
            fprintf(fid, '\n');
        end
        fclose(fid);
    end
end
