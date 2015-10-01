function [softmax_h, h2sInfo] = attnLayerForward(h_t, params, model, trainData, tgtPos)
%%%
%
% Attentional Layer: from lstm hidden state to softmax hidden state.
%
% Thang Luong @ 2015, <lmthang@stanford.edu>
%
%%%
  h2sInfo = [];
  curMask = trainData.curMask;
  if params.attnGlobal % global
    srcHidVecs = trainData.absSrcHidVecs;
    h2sInfo.srcMaskedIds = trainData.srcMaskedIds;
  else % local
    % positions
    if params.predictPos % predictive alignments
      [mu, h2sInfo] = regressPositions(model, h_t, trainData.srcLens, params);
      srcPositions = floor(mu);
    else % monotonic alignments
      srcPositions = tgtPos*ones(1, trainData.curBatchSize);
      flags = srcPositions>(trainData.srcLens-1);
      srcPositions(flags) = trainData.srcLens(flags)-1;
    end
    
    % assert
    if params.assert
      assert(isempty(find(srcPositions<1,1)));
      assert(isempty(find(trainData.tgtLens<=1,1)));
      assert(isempty(find(srcPositions(curMask.unmaskedIds)>(trainData.srcLens(curMask.unmaskedIds)-1),1)));
    end
      
    % reverse
    if params.isReverse
      srcPositions = trainData.srcMaxLen - srcPositions;
    end

    % build context vectors
    [srcHidVecs, h2sInfo] = buildSrcVecs(trainData.srcHidVecs, srcPositions, curMask, params, h2sInfo);

    h2sInfo.srcMaskedIds = find(h2sInfo.alignMask==0);
  end % end else if attnGlobal
  
  % compute alignScores: numAttnPositions * curBatchSize
  % TODO: precompute for attnOpt2 and attnOpt3 (we can premultiply srcHidVecs with W_a (attnOpt2) or W_a_src (attnOpt3)
  if params.attnOpt==1 || params.attnOpt==2 % dot product or general dot product
    if params.attnOpt==1 % dot product
      [alignScores] = srcCompareLayerForward(srcHidVecs, h_t, params);
    elseif params.attnOpt==2 % general dot product
      h2sInfo.transform_ht = model.W_a * h_t; % TODO: shift the multiplication to srcHidVecs
      [alignScores] = srcCompareLayerForward(srcHidVecs, h2sInfo.transform_ht, params);
    end
  elseif params.attnOpt==3 % Bengio's style
    % f(H_src + W_a*h_t): lstmSize * (curBatchSize * numAttnPositions))
    h2sInfo.src_ht_hid = reshape(params.nonlinear_f(bsxfun(@plus, srcHidVecs, model.W_a*h_t)), params.lstmSize, []);

    % v_a * src_ht_hid
    alignScores = linearLayerForward(model.v_a, h2sInfo.src_ht_hid); % 1 * (curBatchSize * numAttnPositions)
    alignScores = reshape(alignScores, params.curBatchSize, params.numAttnPositions)'; % numAttnPositions * curBatchSize
  end  
  
  % normalize -> alignWeights
  h2sInfo.alignWeights = normLayerForward(alignScores, h2sInfo.srcMaskedIds);

  % attn4: local, regression, multiply with distWeights
  if params.predictPos
    [h2sInfo.distWeights, h2sInfo.scaleX] = distLayerForward(mu, h2sInfo, trainData, params); % numAttnPositions*curBatchSize
    h2sInfo.preAlignWeights = h2sInfo.alignWeights;
    h2sInfo.alignWeights =  h2sInfo.preAlignWeights.* h2sInfo.distWeights; % weighted by distances
  end

  % assert
  if params.assert
    assert(computeSum(h2sInfo.alignWeights(h2sInfo.srcMaskedIds), params.isGPU)==0);
  end
  
  h2sInfo.alignWeights(:, curMask.maskedIds) = 0;
  % alignWeights, srcHidVecs -> contextVecs
  [contextVecs] = contextLayerForward(h2sInfo.alignWeights, srcHidVecs, curMask.unmaskedIds, params);

  % f(W_h*[context_t; h_t])
  h2sInfo.input = [contextVecs; h_t];
  h2sInfo.h_t = h_t;
  softmax_h = hiddenLayerForward(model.W_h, h2sInfo.input, params.nonlinear_f);
  h2sInfo.softmax_h = softmax_h; % attentional vectors

  % assert
  if params.assert
    assert(isequal(size(h2sInfo.alignWeights), [params.numAttnPositions, params.curBatchSize]));
    assert(isequal(size(h_t), size(contextVecs))); % lstmSize * curBatchSize
  end
end

function [mu, h2sInfo] = regressPositions(model, h_t, srcLens, params)
  % h_t -> scales=sigmoid(v_pos*f(W_pos*h_t)) in [0, 1]
  [h2sInfo.scales, h2sInfo.posForwData] = scaleLayerForward(model.W_pos, model.v_pos, h_t, params);

  % scales -> srcPositions
  mu = h2sInfo.scales.*(srcLens-1) + 1;
end

    
%     h2sInfo.src_ht_hid = params.nonlinear_f(bsxfun(@plus, srcHidVecs, model.W_a*h_t)); % lstmSize * curBatchSize * numAttnPositions
%     alignScores = squeeze(sum(bsxfun(@times, h2sInfo.src_ht_hid, model.v_a), 1))'; % numAttnPositions * curBatchSize
%     if params.curBatchSize==1 || params.numAttnPositions==1 % handle special cases that causing squeezing to transpose row/col vectors.
%       alignScores = alignScores';
%     end