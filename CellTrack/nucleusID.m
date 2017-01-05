function [output, diagnos] =  nucleusID(nuc_orig,p,data)
%- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
% [output, diagnos] =  nucleusID(nuc_orig,p,data,~) 
%- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
% NUCLEUSID  Find nuclei from images of nuclear-localized fluorophore. Creates separated mask of identified nuclei.
% 
% nuc_orig        input fluorescent image
% p              parameters struture
% data           contains final cell mask from phaseID/ dicID (mask_cell)
%
% label_final    output mask showing cells 
% diag           structure with all masks and label matricies
%
%
% Subfunctions
% watershedalt.m, removemarked.m, bridgenuclei.m
%- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

%- - - - - - - - - - - - - - - - - - - SETUP - - - - - - - - - - - - - - - - - - - - - - -
% Set cutoffs for nuclear shape
cutoff.Area = [floor(pi*(p.MinNucleusRadius-1)^2) ceil(pi*(p.MaxNucleusRadius)^2)];
cutoff.Compactness = p.Compactness;
cutoff.Solidity = p.Solidity;

% Pull out existing mask of cells
cell_mask = data.mask_cell;
% Add any strong nuclei (in case they weren't included in cell mask)
diagnos.thresh1 = quickthresh(nuc_orig,~cell_mask,'none');
tmp = nuc_orig>diagnos.thresh1;
if sum(tmp(:)) < sum(cell_mask(:))
    cell_mask = ~bwareaopen(~(cell_mask|tmp),p.NoiseSize,4);
end
% Construct smoothed images + watershed image
nucleus1 = medfilt2(nuc_orig,[p.MedianFilterSize, p.MedianFilterSize]); % Median-filtered
if isnan(p.NuclearSmooth)
    p.NuclearSmooth = p.MinNucleusRadius/4;
end
diagnos.nucleus_smooth1 = imfilter(nucleus1,gauss2D(p.NuclearSmooth),'replicate'); % Gaussian filtered
diagnos.watershed1 = watershedalt(diagnos.nucleus_smooth1, cell_mask, 4);

%- - - - - - - - - - - - - - - - - - - LABEL1: strong edges  - - - - - - - - - - - - - - - - - - - - - - -
% 1) Iterate down to p.NucleusEdgeThreshold to find strong-edge nuclei
horizontalEdge = imfilter(nucleus1,fspecial('sobel') /8,'symmetric');
verticalEdge = imfilter(nucleus1,fspecial('sobel')'/8,'symmetric');
diagnos.edge_mag = sqrt(horizontalEdge.^2 + verticalEdge.^2);
diagnos.edge_mag(nucleus1==max(nucleus1(:))) = max(diagnos.edge_mag(:)); % Correct for saturated nuclear centers
edge_cutoffs = prctile(diagnos.edge_mag(diagnos.edge_mag>p.NucleusEdgeThreshold),linspace(0,90,21));
cc_list = {};
for i = 1:length(edge_cutoffs)
    % a) Threshold, drop already-found objects
    mask0  = cell_mask & diagnos.edge_mag>=edge_cutoffs((end-i)+1);
    tmp_drop = cell2mat(cc_list');
    if ~isempty(tmp_drop)
        mask0(tmp_drop) = 0;
    end
    % b) Skeletonize/ fill holes
    mask0 = bwmorph(mask0,'skel',2);
    mask0 = bwareaopen(mask0,p.NoiseSize,8);
    mask0 = ~bwareaopen(~mask0,cutoff.Area(2)*4,4);    
    if ~isempty(tmp_drop)
        mask0(tmp_drop) = 0;
    end
    % c) Filter objects that aren't round/sufficently large (alternate btw strict/lenient criteria)
    mask0 = imopen(mask0,diskstrel(round(p.MinNucleusRadius/2)));
    if mod(i-1,4) < 3
        mask0 = bwareaopen(mask0,round(1.3*cutoff.Area(1)),4);
    else
        mask0 = bwareaopen(mask0,cutoff.Area(1),4);
    end
    % d) Add newly-found objects to list
    cc_new = bwconncomp(mask0,8);
    cc_list = cat(2,cc_list,cc_new.PixelIdxList);
end
cc_all.PixelIdxList = cc_list';
cc_all.ImageSize = size(diagnos.edge_mag);
cc_all.NumObjects = length(cc_list);
cc_all.Connectivity = 4;
diagnos.label1a = labelmatrix(cc_all); % Edge-based division lines

% 2) Label1b: subdivide objects using concave points on perimeter (>220 degrees)
diagnos.mask_split = diagnos.label1a>0;
diagnos.mask_split((diagnos.label1a>0)&(imdilate(diagnos.label1a,ones(3))-diagnos.label1a)>0)=0;
diagnos.mask_split = diagnos.mask_split &~perimetersplit(diagnos.mask_split,p);
diagnos.mask_split = bwareaopen(diagnos.mask_split,cutoff.Area(1),4);
cc_inflect = bwconncomp(diagnos.mask_split,4);
diagnos.label1b = labelmatrix(cc_inflect);

% 3) Label1c: subdivide objects with additional borders from watershed
w1 = imdilate(diagnos.watershed1,ones(3));
w1(diagnos.label1b==0) = 0;
pairs  = [w1(:),diagnos.label1b(:)];
[~,~,ic] = unique(pairs,'rows');
diagnos.label1c = reshape(ic,size(w1))-1;
% Simplify objects in label1c to prevent bridgenuclei from hanging
% [Count subobjects per larger object - cap @ 5] 
max_complexity = 6; % Nuclei should be largely broken up by this point.
get_obj = @(pxlist) unique(diagnos.label1c(pxlist));
obj_match = cellfun(get_obj, cc_inflect.PixelIdxList,'UniformOutput',0)';
complex_obj = find(cellfun(@length,obj_match)>max_complexity);
% If complex objects are found, replace them with smoothed/re-watershedded image.
n = 2;
while ~isempty(complex_obj)
    % Use larger smoothing kernel, recalculate watershed, and replace "complex" subregions as required
    nuc_smooth2 = imfilter(nucleus1,gauss2D(min([p.MinNucleusRadius/2*n, (1.25*n)*p.NuclearSmooth])),'replicate'); % Gaussian filtered
    watershed2 = watershedalt(nuc_smooth2, cell_mask, 4);
    for i = 1:length(complex_obj)
        subregion = cc_inflect.PixelIdxList{complex_obj(i)};
        subregion_vals = double(sort(unique(watershed2(subregion))));
        lut = zeros(1,max(subregion_vals)+1);
        lut(subregion_vals+1) = [0,double(max(diagnos.label1c(:)))+(1:(length(subregion_vals)-1))];
        diagnos.label1c(subregion) = lut(watershed2(subregion)+1);
    end
    % Re-count subobjects
    diagnos.label1c = imclose(diagnos.label1c,ones(2));
    get_obj = @(pxlist) unique(diagnos.label1c(pxlist));
    obj_match = cellfun(get_obj, cc_inflect.PixelIdxList,'UniformOutput',0)';
    complex_obj = find(cellfun(@length,obj_match)>max_complexity);
    n = n+1;
end


% 4) Bridge oversegmented nuclear subobjects (from watershed divisions) together by shape
diagnos.label1 = bridgenuclei(diagnos.label1c, cc_inflect, cutoff,p.ShapeDef, p.debug);

%%- - - - - - - - - - - - - - - - - - - Label2 - - - - - - - - - - - - - - - - - - - - - - -
% "Weak" objects missed by standard methods
if p.WeakObjectCutoff>0
    
    % Drop mask1 "marked" watershed areas from watershed of Gaussian-smoothed image 
    label_dropped = imdilate(diagnos.watershed1,ones(3));
    markers = diagnos.label1>0;
    label_dropped = removemarked(label_dropped,markers,'remove')>0;
    nucleus_smooth2 = imfilter(nucleus1,gauss2D(p.MinNucleusRadius/2),'replicate'); % Gaussian filtered
    diagnos.watershed_remainder = imdilate(watershedalt(nucleus_smooth2, cell_mask, 4),ones(3));
    diagnos.watershed_remainder(label_dropped==0) = 0;

    % Rank remaining pixels, and use highest-valued pixels to bridge adjacent watershed regions
    diagnos.weak_ranked = rankpixels(diagnos.watershed_remainder, nucleus1);
    high_valued = bwconncomp(diagnos.weak_ranked==max(diagnos.weak_ranked(:)));
    % Merge watershed areas based on connected "high" areas
    for i = 1:high_valued.NumObjects
        obj = unique(diagnos.watershed_remainder(high_valued.PixelIdxList{i}));
        obj(obj==0) = [];
        if length(obj)>1
            for j = 2:length(obj)
                diagnos.watershed_remainder(diagnos.watershed_remainder==obj(j)) = obj(1);
            end
        end
    end
    diagnos.watershed_remainder((imdilate(diagnos.watershed_remainder,ones(3))-diagnos.watershed_remainder)>0) = 0;
    diagnos.weak_ranked2 = rankpixels(diagnos.watershed_remainder, nucleus1); % Rerank in merged watershed


    % Check that brightest part of "nucleus" is relatively concentric-shaped and contiguous
    test_weak =  diagnos.weak_ranked2 - imerode(diagnos.weak_ranked2,ones(3));
    bright_edge = bwareaopen(test_weak==4,8);
    test_weak(bright_edge) = 100; % Penalize cells with strong intensity values near edge


    % Label2a: based on watershed remainder
    diagnos.label2a = diagnos.watershed_remainder;
    diagnos.weak_objects = zeros(size(test_weak)); % (diagnostic image)
    weak_obj = label2cc(diagnos.label2a);
    for i = 1:weak_obj.NumObjects
        testval = mean(test_weak(weak_obj.PixelIdxList{i}));
        diagnos.weak_objects(weak_obj.PixelIdxList{i}) = min([testval,3]);
        if (testval > p.WeakObjectCutoff) || (testval==0)
            diagnos.label2a(weak_obj.PixelIdxList{i}) = 0;
        end      
    end
    % Clean up label2
    diagnos.label2a(diagnos.weak_ranked2<=2) = 0; % Only look at brightest 25% of area
    diagnos.label2a = imclose(diagnos.label2a,diskstrel(2));
    diagnos.label2a(~imopen(diagnos.label2a>0,diskstrel(floor(p.MinNucleusRadius*2/3)))) = 0;

    % Fix bug where some edge pixels belong to another object
    diagnos.label2a= imerode(imdilate(diagnos.label2a,ones(3)),ones(3));
    diagnos.label2a= imdilate(imerode(diagnos.label2a,ones(3)),ones(3));
    diagnos.label2a = labelmatrix(label2cc(diagnos.label2a));
    cutoff.Area(1) = cutoff.Area(1)*0.5;
    diagnos.label2 = bridgenuclei(diagnos.label2a,bwconncomp(diagnos.label2a>0,4),cutoff,p.ShapeDef, p.debug);
else
    diagnos.label2 = zeros(size(diagnos.label1));
end

% - - - - - - - - - - - - - - - LABEL_END - - - - - - - - - - - - - - - - - - - - -
% Combine label1 and label2.
diagnos.label2(diagnos.label1>0) = 0; % Double check and make sure there's no overlap
diagnos.label2(diagnos.label2>0) = diagnos.label2(diagnos.label2>0)+max(diagnos.label1(:));
output.label_nuc = diagnos.label1+diagnos.label2;

% Relabel contiguously, just in case - convert to double so there are no math errors down the line,
tmp_cc = label2cc(output.label_nuc,1);
output.label_nuc = double(labelmatrix(tmp_cc));


% Save all information under diagnostic struct
diagnos = combinestructures(diagnos,output);


%==================================================================================================



function ranked_image = rankpixels(input_objects, source_image)
%- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - 
% RANKPIXELS outputs a ranked image- input_objects (a bwconncomp structure) are sorted 
% into divisions- the highest 10% pixels are assigned "4", the next 15% are assigned "3",
% then "2", etc.
%
% input_objects       bwconncomp of objects
% source_image        matrix of values to rank
%
% ranked_image        equivalent to size of source_image, can take value of 0-3
%
%- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - 

if ~isstruct(input_objects)
    labelmat = input_objects;
    all_obj = unique(labelmat);
    input_objects = struct;
    input_objects.NumObjects = length(all_obj)-1;
    input_objects.PixelIdxList = cell(1,length(all_obj)-1);
    for i = 1:(length(all_obj)-1)
        input_objects.PixelIdxList{i} = find(labelmat==all_obj(i+1));
    end
end

ranked_image = zeros(size(source_image));
for i = 1:input_objects.NumObjects
    locs = input_objects.PixelIdxList{i};
    if length(locs) < 20
        ranked_image(locs) = 4;
    else
        [~,sort_order] = sort(source_image(locs),'descend'); 
        vals = cat(2,4*ones(1,floor(0.1*length(locs))),3*ones(1,floor(0.15*length(locs))),2*ones(1,floor(0.2*length(locs))));
        vals = cat(2,vals,ones(1,length(locs)-length(vals)));
        ranked_image(locs(sort_order)) = vals;
    end
end


