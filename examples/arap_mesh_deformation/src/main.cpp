﻿#include "main.h"
#include "CombinedSolver.h"
#include "OpenMesh.h"
#include "LandMarkSet.h"
#include <OpenMesh/Tools/Subdivider/Uniform/SubdividerT.hh>
#include <OpenMesh/Tools/Subdivider/Uniform/LongestEdgeT.hh>
#include <OpenMesh/Tools/Subdivider/Uniform/LoopT.hh>
#include <OpenMesh/Tools/Subdivider/Uniform/CatmullClarkT.hh>
#include <OpenMesh/Tools/Subdivider/Uniform/Sqrt3T.hh>
int main(int argc, const char * argv[]) {

	std::string filename = "small_armadillo.ply";
	const char* markerFilename = "small_armadillo.mrk";


	if (argc >= 2) {
		filename = argv[1];
	}
    bool performanceRun = false;
    if (argc >= 3) {
        if (std::string(argv[2]) == "perf") {
            performanceRun = true;
        }
        else {
            printf("Invalid second parameter: %s\n", argv[2]);
        }
    }
	int subdivisionFactor = 0;
	bool lmOnlyFullSolve = false;
	if (argc > 3) {
		lmOnlyFullSolve = true;
		subdivisionFactor = atoi(argv[3]);
		markerFilename = "small_armadillo.mrk";
	}

	// Load Constraints
	LandMarkSet markersMesh;
    markersMesh.loadFromFile(markerFilename);

	std::vector<int>				constraintsIdx;
	std::vector<std::vector<float>> constraintsTarget;

	for (unsigned int i = 0; i < markersMesh.size(); i++)
	{
		constraintsIdx.push_back(markersMesh[i].getVertexIndex());
		constraintsTarget.push_back(markersMesh[i].getPosition());
	}



	SimpleMesh* mesh = new SimpleMesh();

	if (!OpenMesh::IO::read_mesh(*mesh, filename)) 
	{
	        std::cerr << "Error -> File: " << __FILE__ << " Line: " << __LINE__ << " Function: " << __FUNCTION__ << std::endl;
		std::cout << filename << std::endl;
		exit(1);
	}

	OpenMesh::Subdivider::Uniform::Sqrt3T<SimpleMesh> subdivider;
	// Initialize subdivider
	if (lmOnlyFullSolve) {
		if (subdivisionFactor > 0) {
			subdivider.attach(*mesh);
			subdivider(subdivisionFactor);
			subdivider.detach();
		}
	} else {
		//OpenMesh::Subdivider::Uniform::CatmullClarkT<SimpleMesh> catmull;
		// Execute 1 subdivision steps
		subdivider.attach(*mesh);
		subdivider(1);
		subdivider.detach();
	}
    printf("Faces: %d\nVertices: %d\n", mesh->n_faces(), mesh->n_vertices());

    CombinedSolverParameters params;
    params.numIter = 96;
    //params.useCUDA = true;
    params.nonLinearIter = 20;
    params.linearIter = 1000;
    params.useOpt = true;
    params.earlyOut = true;



    if (performanceRun) {
        params.useCUDA = false;
        params.useTerra = false;
        params.useOpt = true;
        params.useOptLM = true;
        params.useCeres = true;
        params.earlyOut = true;
        params.nonLinearIter = 20;
        params.linearIter = 1000;
    }
    if (lmOnlyFullSolve) {
        params.useCUDA = false;
        params.useOpt = false;
        params.useOptLM = true;
        params.linearIter = 1000;// m_image.getWidth()*m_image.getHeight();
        if (mesh->n_vertices() > 100000) {
            params.nonLinearIter = mesh->n_vertices() / 5000;
        }
    }
    params.useCUDA = true;
    params.useOpt = true;
    params.useOptLM = true;
    params.useCeres = true;
    params.earlyOut = true;
    params.optDoublePrecision = false;
    CombinedSolver solver(mesh, constraintsIdx, constraintsTarget, params);
    solver.solveAll();
    SimpleMesh* res = solver.result();
	if (!OpenMesh::IO::write_mesh(*res, "out.ply"))
	{
	        std::cerr << "Error -> File: " << __FILE__ << " Line: " << __LINE__ << " Function: " << __FUNCTION__ << std::endl;
		std::cout << "out.off" << std::endl;
		exit(1);
	}

	return 0;
}
